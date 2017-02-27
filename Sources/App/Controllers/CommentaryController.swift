import HTTP
import JSON
import Vapor
import Auth
import Foundation
import JWT
import Node
import Cookies
import FluentMySQL

final class CommentaryController{
    let pubDrop: Droplet
    let jwtSigner: Signer
    let templateDir: String
    let filePackDir: String
    let submitRender: LeafRenderer
    let fm = FileManager()
    enum PreviewView {
        case fullText
        case onlyComments
    }
    
    init(to drop: Droplet) {
        pubDrop = drop
        templateDir = drop.workDir + "TemplatePacks/"
        filePackDir = drop.workDir + "FilePacks/"
        submitRender = LeafRenderer(viewsDir: drop.viewsDir)
        jwtSigner = HS256(key: (drop.config["crypto", "jwtcommentary","secret"]?.string ?? "secret").bytes)
        let previewer = drop.grouped("documents",":id","commentaries")
        previewer.get("summary", handler: commentarySummary)
        previewer.get("submit",":command", handler: commentarySubmit)
        previewer.post("submit",":command", handler: commentarySubmit)

        previewer.get( handler: commentaryLoad)
        
    }
    func commentaryLoad(_ request: Request)throws -> ResponseRepresentable {
        guard let documentId = request.parameters["id"]?.string else {
            throw Abort.badRequest
        }
        var commid: UInt?
        guard documentId != "undefined" else {throw Abort.custom(status: .badRequest, message: "document not specified")}
        let idInt = Base62ToID(string: documentId)
        let documentdata = try Document.find(Node(idInt))
        guard documentdata != nil else {throw Abort.custom(status: .notFound, message: "document unknown")}
        var commentary: Commentary?
        var commentJWT: JWT?
        var refreshOfCookie = false
        if let incookie = request.cookies[ConsultConstants.cookieComment] {
            commentJWT = try? JWT(token: incookie)
        }
        pubDrop.console.info("Headers \(request.headers)")
        if commentJWT != nil {
            do {
                try commentJWT!.verifySignature(using: jwtSigner)
                commid = commentJWT!.payload["commid"]?.uint
            } catch {
                refreshOfCookie = true            }
        } else {
            refreshOfCookie = true
        }

        if  commid != nil {
            do{
                pubDrop.console.info("looking for \(commid!)")

                commentary = try Commentary.find(Node(commid!))
            } catch{
                throw Abort.custom(status: .internalServerError, message: "commentary lookup failure")
            }

        }
        var response: [String: Node] = [:]
        if commentary != nil {
        
            var results: [Node] = []
            if let cid = commentary?.id{
                let comments = try Comment.query().filter("commentary_id", cid).all()
                //make Json array of comments with Node bits
                for comment in comments {
                    if let thisResult = comment.nodeForJSON() {
                        results.append(thisResult)
                    }
                }
            }
            response["comments"] = Node(results)
            response["commentary"] = commentary!.nodeForJSON()
        } else {
            refreshOfCookie = true
        }
        let headers: [HeaderKey: String] = [
            "Content-Type": "application/json; charset=utf-8"
        ]
        let json = JSON(Node(response))
        let resp = Response(status: .ok, headers: headers, body: try Body(json))
        // cookie refresh if configuration specified
        if  let domname = pubDrop.config["app", "appdomain"]?.string {
            if commentary != nil {
                if commentJWT == nil {
                    commentJWT = try JWT(payload: Node.object(["commid":Node(commid!)]),
                                         signer: jwtSigner)
                }
                if let token = try commentJWT?.createToken() {
                    let myCookie = Cookie(name: ConsultConstants.cookieComment,value: token, expires: Date() + 7 * 24 * 3600, domain: domname, httpOnly: true)
                    resp.cookies.insert(myCookie)
                }
            } else {
                //need to kill the cookie for various reasons above
                let myCookie = Cookie(name: ConsultConstants.cookieComment,value: "", maxAge: 0, domain: domname, httpOnly: true)
                resp.cookies.insert(myCookie)
            }
        }
        return resp
    }
    func commentarySubmit(_ request: Request)throws -> ResponseRepresentable {
        guard let documentId = request.parameters["id"]?.string else {
            throw Abort.badRequest
        }
        guard let command = request.parameters["command"]?.string else {
            throw Abort.badRequest
        }
        var commid: UInt?
        guard documentId != "undefined" else {throw Abort.custom(status: .badRequest, message: "document not specified")}
        let idInt = Base62ToID(string: documentId)
        let documentdata = try Document.find(Node(idInt))
        guard documentdata != nil else {throw Abort.custom(status: .notFound, message: "document unknown")}
        var commentary: Commentary?
        var commentJWT: JWT?
        var refreshOfCookie = false
        if let incookie = request.cookies[ConsultConstants.cookieComment] {
            commentJWT = try? JWT(token: incookie)
        }
        pubDrop.console.info("Headers \(request.headers)")
        if command == "clear" {
            let detectedLanguage = languageDetect(request)
            let resp = Response(status: .found)
            resp.headers["Location"] = documentdata?.publishedURL(languageStr: detectedLanguage)?.absoluteString ?? "/"

            //need to kill the cookie for various reasons above
            if  let domname = pubDrop.config["app", "appdomain"]?.string {
                let myCookie = Cookie(name: ConsultConstants.cookieComment,value: "", maxAge: 0, domain: domname, httpOnly: true)
                resp.cookies.insert(myCookie)
            }
            return resp
        }
        if commentJWT != nil {
            do {
                try commentJWT!.verifySignature(using: jwtSigner)
                commid = commentJWT!.payload["commid"]?.uint
            } catch {
                refreshOfCookie = true            }
        } else {
            refreshOfCookie = true
        }

        if  commid != nil {
            do{
                pubDrop.console.info("looking for \(commid!)")

                commentary = try Commentary.find(Node(commid!))
            } catch{
                throw Abort.custom(status: .internalServerError, message: "commentary lookup failure")
            }

        }
        var response: [String: Node] = [:]
        if commentary != nil {
            switch command {
                case "request":
                    fallthrough
                default:
                    if commentary!.submitted {
                        if let submittedalready = try? submitRender.make("submittedalready", [
                            "document-id": documentId,
                            "startnewoption": true,
                            "emailoption": true,
                            "lang-eng": true,
                            "lang-fra": false

                            ]) {
                            response["overlayhtml"] = try? Node(submittedalready.data.string())
                        }
                    } else {
                        if let submitverify = try? submitRender.make("submitrequest", [
                            "document-id": documentId
                            ]) {
                            response["overlayhtml"] = try? Node(submitverify.data.string())
                        }
                    }

            }
            response["commentary"] = commentary!.nodeForJSON()
        } else {
            refreshOfCookie = true
        }
        let headers: [HeaderKey: String] = [
            "Content-Type": "application/json; charset=utf-8"
        ]
        let json = JSON(Node(response))
        let resp = Response(status: .ok, headers: headers, body: try Body(json))
        // cookie refresh if configuration specified
        if  let domname = pubDrop.config["app", "appdomain"]?.string {
            if commentary != nil {
                if commentJWT == nil {
                    commentJWT = try JWT(payload: Node.object(["commid":Node(commid!)]),
                                         signer: jwtSigner)
                }
                if let token = try commentJWT?.createToken() {
                    let myCookie = Cookie(name: ConsultConstants.cookieComment,value: token, expires: Date() + 7 * 24 * 3600, domain: domname, httpOnly: true)
                    resp.cookies.insert(myCookie)
                }
            } else {
                //need to kill the cookie for various reasons above
                let myCookie = Cookie(name: ConsultConstants.cookieComment,value: "", maxAge: 0, domain: domname, httpOnly: true)
                resp.cookies.insert(myCookie)
            }
        }
        return resp
    }

    func commentarySummary(_ request: Request)throws -> ResponseRepresentable {
        guard let documentId = request.parameters["id"]?.string else {
            throw Abort.badRequest
        }
        var commid: UInt?
        let idInt = Base62ToID(string: documentId)
        let documentdata = try Document.find(Node(idInt))
        //TODO: document not found errors
        guard documentdata != nil else {return Response(redirect: "/")}
        var commentary: Commentary?
        var commentJWT: JWT?
        if let incookie = request.cookies[ConsultConstants.cookieComment] {
            commentJWT = try? JWT(token: incookie)
        }
        let detectedLanguage = languageDetect(request)
        guard commentJWT != nil else {return Response(redirect: documentdata?.publishedURL(languageStr: detectedLanguage)?.absoluteString ?? "/")}

        do {
            try commentJWT!.verifySignature(using: jwtSigner)
                commid = commentJWT!.payload["commid"]?.uint
        } catch {
            commentJWT = nil  //did not pass - new one will be started
        }

        if  commid != nil {
            do{
                pubDrop.console.info("looking for \(commid!)")
                commentary = try Commentary.find(Node(commid!))
            } catch{
                pubDrop.console.info("Did not find \(commid)")
            }
        }


        guard commentary != nil else {return Response(redirect: documentdata?.publishedURL(languageStr: detectedLanguage)?.absoluteString ?? "/")}


        return try buildCommentaryPreview(request, document: documentdata!, commentary: commentary!, type: .onlyComments)
    }

    func buildCommentaryPreview(_ request: Request, document: Document, commentary: Commentary, type: PreviewView)throws -> ResponseRepresentable {
        let filePackBaseDir = filePackDir + document.filepack!
        let filePack = filePackBaseDir + "/elements/"
        //TODO: need new document types in future
        let templatePack = templateDir + "proposedregulation/elements/"
        var filejson: [String: Any] = [:]
        var tags: [[String: Any]] = [[:]]
        //        let docRenderer = LeafRenderer(viewsDir: filePack)
        let tempRenderer = LeafRenderer(viewsDir: templatePack)
        //find page language from referrer
        var tagsDict: [String:[String: Any]] = [:]
        var fileJson: JSON = JSON(.null)
        //get data from disk/network
        if let data = fm.contents(atPath: filePackBaseDir + "/filepack.json") {
            fileJson = try! JSON(serialized: data.makeBytes())

            if let fj =  try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                filejson = fj!
                if let thetags = filejson["reg-tags"] as? [[String: Any]] {
                    // Finally we got the tags
                    tags = thetags
                    // need to unique the tags as they will need to be unique id elements in the html
                    //TODO: warn and clean step in preflight
                    var tagset: Set<String> = []
                    for (index, tag) in tags.enumerated() {
                        var theref = tag["ref"] as? String
                        if (theref ?? "").isEmpty {
                            theref = "t-\(index)"
                        }
                        if tagset.contains(theref!) {
                            theref = theref! + "-t-\(index)"
                            guard !tagset.contains(theref!) else {
                                return JSON(["prepare":"regulation","status":"failed"])
                            }
                        }
                        tags[index]["ref"] = theref
                        tagsDict["reg-" + theref!] = tags[index]
                        tagset.insert(theref!)
                    }
                }
            }
        }
        let pagePrefix = fileJson.node.nodeObject?["publishing-pageprefix"]?.string ?? "reg"
        var substitutions: [String:Node] = [:]

        let comments = try Comment.query().filter("commentary_id", commentary.id!).all()

        let lang = languageDetect(request) == "fra" ? ("fra","line-fra","line-eng","fr-CA","prompt-fra") : ("eng","line-eng","line-fra","en-CA","prompt-eng")

        var tempNode: [String: Node] = fileJson.node.nodeObject ?? [:]
        tempNode[lang.1] = Node(true) //use in template to select language
        tempNode["eng-page"] = Node(pagePrefix + "-eng.html")
        tempNode["fra-page"] = Node(pagePrefix + "-fra.html")
        tempNode["document-link"] = Node("/" + document.publishingpath!)
        if let langDict = tempNode[lang.3]?.nodeObject {
            for (item, nodeElement) in langDict {
                tempNode[item] = nodeElement

            }
        }
        tempNode["noformend"] = Node("noformend")
        
        let fnode = Node(tempNode)
        var outDocument = Data()

        if let meta = try? tempRenderer.make("commentpreviewbanner-" + lang.0, fnode) {
            outDocument.append(Data(meta.data))
        }
        if let meta = try? tempRenderer.make("summarylead-" + lang.0, fnode) {
            outDocument.append(Data(meta.data))
        }
        if let meta = try? tempRenderer.make("commentpreviewlistlead-" + lang.0, fnode) {
            outDocument.append(Data(meta.data))
        }
        switch type {
        case .fullText:
            
            if let section = fm.contents(atPath: filePack + "rias-" + lang.0 + ".html") {
                outDocument.append(section) }

            if let section = fm.contents(atPath: filePack + "reg-" + lang.0 + ".html") {
                if var dataString:[String] = String(data: section, encoding: String.Encoding.utf8)?.components(separatedBy: .newlines) {
                    substitutions["reftype"] = Node(String(describing: "reg"))

                    for comment in comments {
                        if let thisRef = comment.reference, let thisTag = tagsDict[thisRef] {
                            if let linenum = thisTag[lang.1] as? Int{
                                guard linenum <= dataString.count else {continue}
                                substitutions["ref"] = Node(thisTag["ref"] as! String) //tag["ref"] as? String
                                if let pmt = thisTag[lang.4] as? String {
                                    substitutions["prompt"] = Node(pmt) // as? String) // as? String
                                } else {
                                    substitutions["prompt"] = nil
                                }
                                if let txt = comment.text {
                                    substitutions["commenttext"] = Node(txt)
                                    let insertType = (thisTag["type"] as? String ?? "comment") + "preview-" + lang.0
                                    if let meta = try? tempRenderer.make(insertType, substitutions), let templstr = String(data: Data(meta.data), encoding: String.Encoding.utf8) {
                                        dataString[linenum - 1] = dataString[linenum - 1].appending(templstr)
                                    }
                                }
                            }
                        }
                    }

                    substitutions["ref"] = nil
                    substitutions["prompt"] = nil
                    substitutions["commenttext"] = nil
                    outDocument.append(dataString.joined(separator: "\n").data(using: .utf8)!)
                }
            }
            if let meta = try? tempRenderer.make("previewsubmit-" + lang.0, fnode) {
                outDocument.append(Data(meta.data))
            }
        case .onlyComments:
            var commentDict: [String: Comment] = [:]
            for comment in comments {
                guard let cref = comment.reference else { continue}
                commentDict[cref] = comment
            }
            if let section = fm.contents(atPath: filePack + "reg-" + lang.0 + ".html") {
                if var dataString:[String] = String(data: section, encoding: String.Encoding.utf8)?.components(separatedBy: .newlines) {
                    var lastline: Int = 0

                    substitutions["reftype"] = Node(String(describing: "reg"))
                    for tag in tags {
                        if let linenum = tag[lang.1] as? Int{
                            guard linenum <= dataString.count else {continue}
                            substitutions["ref"] = Node(tag["ref"] as! String) 
                            if let pmt = tag[lang.4] as? String {
                                substitutions["prompt"] = Node(pmt)
                            } else {
                                substitutions["prompt"] = nil
                            }
                            if let comm = commentDict["reg-" + (tag["ref"] as! String)], let txt = comm.text {
                                substitutions["emptycomment"] = false
                                substitutions["commenttext"] = Node(txt)

                            } else {
                                substitutions["emptycomment"] = true
                                substitutions["commenttext"] = nil
                            }
                            let insertTypehead = (tag["type"] as? String ?? "comment") + "previewlisthead-" + lang.0
                            if let meta = try? tempRenderer.make(insertTypehead, substitutions), let templstr = String(data: Data(meta.data), encoding: String.Encoding.utf8) {
                                dataString[lastline] = templstr.appending(dataString[lastline])                            }
                            let insertType = (tag["type"] as? String ?? "comment") + "previewlist-" + lang.0
                            if let meta = try? tempRenderer.make(insertType, substitutions), let templstr = String(data: Data(meta.data), encoding: String.Encoding.utf8) {
                                dataString[linenum - 1] = dataString[linenum - 1].appending(templstr)
                            }
                            lastline = linenum

                        }
                    }
                    substitutions["ref"] = nil
                    substitutions["prompt"] = nil
                    substitutions["commenttext"] = nil
                    outDocument.append(dataString.joined(separator: "\n").data(using: .utf8)!)


                }
            }

        } //switch
        if let meta = try? tempRenderer.make("commentpreviewlisttail-" + lang.0, fnode) {
            outDocument.append(Data(meta.data))
        }
        if let meta = try? tempRenderer.make("commentpreviewfoot-" + lang.0, fnode) {
            outDocument.append(Data(meta.data))
        }


        return View(data: [UInt8](outDocument))
    }

}