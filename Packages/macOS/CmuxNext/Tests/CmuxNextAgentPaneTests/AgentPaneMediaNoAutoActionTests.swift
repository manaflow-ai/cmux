@testable import CmuxNextAgentPane
import AppKit
import CmuxNextRemoteFetch
import CmuxNextSettings
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// No automatic fetch and no automatic open from an agent's media (media-safety plan R5 and R7,
/// leo-workspace#874). Leo 2026-10-21: "we want to make it prompt injection safe as well since
/// images to remote is maybe dangerous to remote". With the default `agentPane.images.remote`
/// (`click`), a reply's web image or video is fetched only after the reader's click, and only by
/// the host; no request about a reply's media (load, play, inspect) ever reaches an opener, a
/// browser, a file page, Finder or Quick Look; and `media.load` answers only the pane's own media
/// URLs. Every effect is a spy, so "nothing happened" is what the spies saw, not only the reply.
@MainActor
struct AgentPaneMediaNoAutoActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Every URL the host fetched, answering `body`.
    private nonisolated final class Fetches: AgentPaneImageFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        /// The hosts each fetch was held to (nil: any host).
        private var limits: [Set<String>?] = []
        private let body: Data
        init(body: Data) { self.body = body }
        var all: [URL] { lock.withLock { urls } }
        var hosts: [Set<String>?] { lock.withLock { limits } }
        func fetch(_ url: URL) async -> Result<Data, AgentPaneReplyError> {
            lock.withLock { urls.append(url); limits.append(nil) }
            return .success(body)
        }
        func fetch(_ url: URL, within hosts: Set<String>) async -> Result<Data, AgentPaneReplyError> {
            lock.withLock { urls.append(url); limits.append(hosts) }
            return .success(body)
        }
    }

    /// Every effect outside the page: openers, Finder, Quick Look, the pasteboard, drags, browsers.
    private final class Effects {
        var seen: [String] = []
    }

    private final class Browsers: AgentPaneBrowserApps {
        let effects: Effects
        init(_ effects: Effects) { self.effects = effects }
        func applications() -> [URL] { [URL(fileURLWithPath: "/Applications/Safari.app")] }
        func displayName(of app: URL) -> String { "Safari" }
        func iconPNG(of app: URL) -> Data? { nil }
        func open(_ url: URL, withApplicationAt app: URL) { effects.seen.append("browser \(url)") }
    }

    private struct Pane {
        let model: AgentPaneModel
        let effects: Effects
        let images: Fetches
        let media: Fetches
        let project: URL
    }

    /// A 2x2 PNG, so a local image decodes.
    private static let png: Data = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let output = NSMutableData()
        if let image = context?.makeImage(),
           let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            _ = CGImageDestinationFinalize(destination)
        }
        return output as Data
    }()

    /// The first bytes of an MP4 (`ftyp isom`), which the web media copy sniffs.
    private static let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(count: 16)

    private static func pane(setting: AgentPaneReplySetting = .fallback) throws -> Pane {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-no-auto-\(UUID().uuidString)", isDirectory: true)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let model = AgentPaneModel(host: NoHost())
        let effects = Effects()
        let images = Fetches(body: png), media = Fetches(body: mp4)
        let links = model.replyLinks
        links.settings = { setting }
        links.fetcher = images
        links.mediaFetcher = media
        links.imageFolder = folder.appendingPathComponent("copies", isDirectory: true)
        links.revealFolder = { effects.seen.append("revealFolder \($0.path)") }
        links.revealFile = { effects.seen.append("revealFile \($0.path)") }
        links.quickLookFile = { effects.seen.append("quickLook \($0.path)") }
        links.saveFile = { file, _ in effects.seen.append("save \(file.path)") }
        links.copyItem = { _ in effects.seen.append("copy"); return true }
        links.mouseHeld = { false }
        links.startDrag = { effects.seen.append("drag \($0.path)"); return true }
        links.browsers = Browsers(effects)
        model.onOpenFile = { url, _ in effects.seen.append("file \(url.path)"); return true }
        model.onOpenPreview = { effects.seen.append("preview \($0)"); return true }
        model.workspaceRoots = { [project.path] }
        return Pane(model: model, effects: effects, images: images, media: media, project: project)
    }

    private static func ask(_ pane: Pane, _ method: String, _ params: [String: Any], click: Bool = false) async -> [String: Any] {
        if click { pane.model.transport.gestures.record(click: true) }
        return await pane.model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static func src(_ reply: [String: Any]) -> String? {
        (reply["value"] as? [String: Any])?["src"] as? String
    }

    /// A web address no other test fetched (web media copies are kept per address for the app's life).
    private static func web(_ ext: String) -> String { "https://media.example.com/\(UUID().uuidString).\(ext)" }

    // MARK: R5: no automatic fetch

    @Test func theDefaultSettingIsStillClickAndAlwaysIsStillOffered() {
        // `images.remote = always` stays a choice (Leo's rule: no component removed, no default flipped).
        #expect(AgentPaneReplySetting.fallback.remoteImages == .click)
        #expect(AgentPaneReplySetting.RemoteImages.allCases.map(\.rawValue).sorted() == ["always", "click", "never"])
    }

    @Test func aWebImageAndVideoAreFetchedOnlyAfterAClickAndOnlyOnce() async throws {
        let pane = try Self.pane()
        let image = Self.web("png"), video = Self.web("mp4")

        // Drawing the reply: its chips are inspected and both loads are asked, with no click.
        let inspect = await Self.ask(pane, "link.inspect", ["paths": [String](), "urls": [image, video]])
        #expect(Self.errorCode(inspect) == nil, "\(inspect)")
        let noClickImage = await Self.ask(pane, "image.load", ["src": image])
        #expect(Self.errorCode(noClickImage) == AgentPaneReplyError.gestureRequired.rawValue)
        let noClickVideo = await Self.ask(pane, "media.load", ["src": video])
        #expect(Self.errorCode(noClickVideo) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(pane.images.all.isEmpty, "a web image was fetched with no click")
        #expect(pane.media.all.isEmpty, "a web video was fetched with no click")

        // Load image: one fetch, through the host, answered as a data URL.
        let clickedImage = await Self.ask(pane, "image.load", ["src": image], click: true)
        #expect(Self.src(clickedImage)?.hasPrefix("data:image/png;base64,") == true, "\(clickedImage)")
        #expect(pane.images.all == [URL(string: image)!])
        // Drawing it again later asks again; the host does not fetch again by itself.
        let again = await Self.ask(pane, "image.load", ["src": image])
        #expect(Self.errorCode(again) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(pane.images.all.count == 1)

        // Load video: one fetch, played from the pane's own media URL.
        let clickedVideo = await Self.ask(pane, "media.load", ["src": video], click: true)
        #expect(Self.src(clickedVideo)?.hasPrefix("cmux-agent://pane/__media/") == true, "\(clickedVideo)")
        #expect(pane.media.all == [URL(string: video)!])
        #expect(pane.effects.seen.isEmpty, "\(pane.effects.seen)")
    }

    @Test func aPRMediaImageLoadsWithNoClickHeldToItsSiteAndSpendsNoGesture() async throws {
        let pane = try Self.pane()
        let sources = [
            "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/24546/before-dark.png",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/24546/after-dark.png",
        ]
        // A click the person made for something else is still pending through both loads.
        pane.model.transport.gestures.record(click: true)
        for source in sources {
            let reply = await Self.ask(pane, "image.load", ["src": source, "auto": true])
            #expect(Self.src(reply)?.hasPrefix("data:image/png;base64,") == true, "\(source): \(reply)")
        }
        #expect(pane.images.all == sources.map { URL(string: $0)! })
        #expect(pane.images.hosts == [AgentPaneSafeFetch.clickFreeImageHosts, AgentPaneSafeFetch.clickFreeImageHosts])
        // That click still counts for an image that needs one, and it fetches as before.
        let other = await Self.ask(pane, "image.load", ["src": Self.web("png")])
        #expect(Self.src(other) != nil, "\(other)")
        #expect(pane.images.hosts.last == .some(nil))
        // The page learns the sites from the policy.
        let inspect = await Self.ask(pane, "link.inspect", ["paths": [String](), "urls": [String]()])
        let policy = (inspect["value"] as? [String: Any])?["policy"] as? [String: Any]
        #expect(policy?["clickFreeImageHosts"] as? [String] == ["raw.githubusercontent.com"])
        #expect(pane.effects.seen.isEmpty, "\(pane.effects.seen)")
    }

    @Test func anImageFromAnotherSiteALookalikeOrAnOddSpellingStillWaitsForAClick() async throws {
        let pane = try Self.pane()
        let sources = [
            // github.com stays behind the click: a release asset's download count shows its owner each fetch.
            "https://github.com/attacker/repo/releases/download/v1/pixel.png", "https://github.com/o/r/raw/main/a.png",
            "https://raw.githubusercontent.com.evil.example/a.png", "https://evilraw.githubusercontent.com/a.png",
            "https://raw-githubusercontent.com/a.png", "https://camo.githubusercontent.com/a.png",
            "https://media.githubusercontent.com/media/o/r/main/a.png", "https://evil.example/raw.githubusercontent.com/a.png",
            "https://evil.example/?u=https://raw.githubusercontent.com/a.png", "https://raw.githubusercontent.com:8443/a.png",
            "https://raw.githubusercontent.com:443/a.png", "https://raw.githubusercontent.com./a.png",
            "https://RAW.githubusercontent.com/a.png", "https://raw.githubusercontent%2Ecom/a.png",
            "https://raw.githubusercontent.com", "https://raw.githubusercontent.com?a.png",
        ]
        for source in sources {
            // The page's own load: refused, and the pending click is not spent on it.
            pane.model.transport.gestures.record(click: true)
            let auto = await Self.ask(pane, "image.load", ["src": source, "auto": true])
            #expect(Self.errorCode(auto) != nil, "\(source): \(auto)")
            #expect(pane.images.all.isEmpty, "\(source) was fetched with no click")
            #expect(pane.model.transport.gestures.consume(), "\(source) spent the pending click")
            // With no click at all, the same.
            let bare = await Self.ask(pane, "image.load", ["src": source])
            #expect(Self.errorCode(bare) != nil, "\(source): \(bare)")
        }
        for source in ["http://raw.githubusercontent.com/a.png", "https://u:p@raw.githubusercontent.com/a.png"] {
            let reply = await Self.ask(pane, "image.load", ["src": source, "auto": true])
            #expect(Self.errorCode(reply) == AgentPaneReplyError.imageRefused.rawValue, "\(source): \(reply)")
        }
        #expect(pane.images.all.isEmpty, "\(pane.images.all)")
        // `auto` is a boolean or absent; anything else breaks the contract.
        #expect(AgentPaneReplyRequest(method: "image.load", params: ["src": "https://raw.githubusercontent.com/a.png", "auto": "yes"]) == nil)
        // A web video from GitHub is unchanged: it still waits for a click.
        let video = await Self.ask(pane, "media.load", ["src": "https://raw.githubusercontent.com/o/r/main/\(UUID().uuidString).mp4"])
        #expect(Self.errorCode(video) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(pane.media.all.isEmpty)
    }

    @Test func underNeverAPRMediaImageIsRefusedAndUnderAlwaysItIsNotHeldToItsSite() async throws {
        let github = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/1/a.png"
        let never = try Self.pane(setting: AgentPaneReplySetting(outsideRoots: .open, remoteImages: .never))
        let refused = await Self.ask(never, "image.load", ["src": github, "auto": true], click: true)
        #expect(Self.errorCode(refused) == AgentPaneReplyError.imageRefused.rawValue)
        #expect(never.images.all.isEmpty)
        let always = try Self.pane(setting: AgentPaneReplySetting(outsideRoots: .open, remoteImages: .always))
        _ = await Self.ask(always, "image.load", ["src": github])
        #expect(always.images.hosts == [nil])
    }

    @Test func aClickFreeFetchNeverConnectsToAHostOffTheList() async throws {
        let transport = Hops()
        let fetch = AgentPaneSafeFetch(guarded: GuardedRemoteFetch(
            maximumBytes: 1 << 20, timeout: .seconds(5), accept: GuardedRemoteFetch.imageAccept,
            resolver: PublicResolver(), transport: transport))
        let sites = AgentPaneSafeFetch.clickFreeImageHosts
        // raw.githubusercontent.com redirects to another site (an LFS file, a tracker): refused before it connects there.
        transport.redirects = ["raw.githubusercontent.com/a.png": "https://tracker.example/pixel.png"]
        let offList = await fetch.fetch(URL(string: "https://raw.githubusercontent.com/a.png")!, within: sites)
        #expect(offList == .failure(.imageRefused))
        #expect(transport.hosts == ["raw.githubusercontent.com"])
        // A redirect within the site (a renamed repository) is followed.
        transport.redirects = ["raw.githubusercontent.com/old/r/main/a.png": "https://raw.githubusercontent.com/new/r/main/a.png"]
        let renamed = await fetch.fetch(URL(string: "https://raw.githubusercontent.com/old/r/main/a.png")!, within: sites)
        #expect(renamed == .success(Data("png".utf8)))
        #expect(transport.hosts.suffix(2) == ["raw.githubusercontent.com", "raw.githubusercontent.com"])
        // A click's fetch is as before: it follows a redirect to any public site.
        transport.redirects = ["raw.githubusercontent.com/a.png": "https://tracker.example/pixel.png"]
        let clicked = await fetch.fetch(URL(string: "https://raw.githubusercontent.com/a.png")!)
        #expect(clicked == .success(Data("png".utf8)))
        #expect(transport.hosts.suffix(2) == ["raw.githubusercontent.com", "tracker.example"])
    }

    private nonisolated struct PublicResolver: RemoteAddressResolving {
        func resolve(_ host: String) async throws -> [RemoteAddress] { [.v4([140, 82, 112, 3])] }
    }

    /// Answers a redirect for each host and path in `redirects` ("host/path") and "png" for any
    /// other; records each host it was sent to.
    private nonisolated final class Hops: RemoteFetchTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private var targets: [String: String] = [:]
        var hosts: [String] { lock.withLock { seen } }
        var redirects: [String: String] {
            get { lock.withLock { targets } }
            set { lock.withLock { targets = newValue } }
        }
        func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
            let target = lock.withLock { () -> String? in
                seen.append(request.host)
                return targets[request.host + request.target]
            }
            if let target { return RemoteFetchResponse(status: 302, headers: ["location": target], body: Data()) }
            return RemoteFetchResponse(status: 200, headers: [:], body: Data("png".utf8))
        }
    }

    @Test func underNeverAClickFetchesNothing() async throws {
        let pane = try Self.pane(setting: AgentPaneReplySetting(outsideRoots: .open, remoteImages: .never))
        let image = await Self.ask(pane, "image.load", ["src": Self.web("png")], click: true)
        #expect(Self.errorCode(image) == AgentPaneReplyError.imageRefused.rawValue)
        let video = await Self.ask(pane, "media.load", ["src": Self.web("mp4")], click: true)
        #expect(Self.errorCode(video) == AgentPaneReplyError.mediaRefused.rawValue)
        #expect(pane.images.all.isEmpty && pane.media.all.isEmpty)
        #expect(pane.effects.seen.isEmpty, "\(pane.effects.seen)")
    }

    @Test func anAppLinkScriptOrNonHTTPSSourceIsRefusedBeforeAnyFetchOrOpen() async throws {
        let pane = try Self.pane()
        let sources = [
            "cmux://workspace/ws_0123456789abcdef0123456789abcdef", "cmux-dev-tag://session/abc", "cmux://agent/x",
            "javascript:alert(1)", "vscode://file/etc/hosts", "ssh://host/x.png", "ftp://example.com/a.png",
            "http://example.com/a.png", "https://127.0.0.1/a.png", "https://localhost/a.mp4", "https://u:p@example.com/a.png",
            "data:image/svg+xml;base64,PHN2Zy8+", "data:video/mp4;base64,AAAA",
        ]
        for source in sources {
            let image = await Self.ask(pane, "image.load", ["src": source], click: true)
            #expect(Self.errorCode(image) != nil, "image.load \(source): \(image)")
            let media = await Self.ask(pane, "media.load", ["src": source], click: true)
            #expect(Self.errorCode(media) != nil, "media.load \(source): \(media)")
        }
        #expect(pane.images.all.isEmpty && pane.media.all.isEmpty)
        #expect(pane.effects.seen.isEmpty, "\(pane.effects.seen)")
    }

    // MARK: R7: no action from media

    @Test func loadingAndPlayingLocalMediaOpensNothingAndAnswersOnlyThePanesMediaURLs() async throws {
        let pane = try Self.pane()
        let shot = pane.project.appendingPathComponent("shot.png"), clip = pane.project.appendingPathComponent("clip.mp4")
        let page = pane.project.appendingPathComponent("page.html"), drawing = pane.project.appendingPathComponent("drawing.svg")
        try Self.png.write(to: shot)
        try Self.mp4.write(to: clip)
        try Data("<script>location='cmux://workspace/x'</script>".utf8).write(to: page)
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg"><a href="cmux://workspace/x"><rect width="1" height="1"/></a></svg>"#.utf8)
            .write(to: drawing)

        let inspect = await Self.ask(pane, "link.inspect", ["paths": [shot.path, clip.path, page.path, drawing.path], "urls": [String]()])
        #expect(Self.errorCode(inspect) == nil, "\(inspect)")
        let image = await Self.ask(pane, "image.load", ["src": shot.path])
        #expect(Self.src(image)?.hasPrefix("data:image/png;base64,") == true, "\(image)")
        let svg = await Self.ask(pane, "image.load", ["src": drawing.path])
        let svgSource = try #require(Self.src(svg))
        #expect(svgSource.hasPrefix("data:image/svg+xml;base64,"))
        let svgText = String(decoding: Data(base64Encoded: String(svgSource.drop { $0 != "," }.dropFirst())) ?? Data(), as: UTF8.self)
        #expect(!svgText.contains("cmux:"), "\(svgText)")

        let video = await Self.ask(pane, "media.load", ["src": clip.path])
        let played = try #require(Self.src(video))
        #expect(played.hasPrefix("cmux-agent://pane/__media/"))
        let playedURL = try #require(URL(string: played))
        #expect(AgentPaneMediaGrants.shared.file(for: playedURL)?.resolvingSymlinksInPath() == clip.resolvingSymlinksInPath())
        // Neither a web page nor an image plays as media: `media.load` grants only what the pane plays.
        for path in [page.path, drawing.path, shot.path] {
            let refused = await Self.ask(pane, "media.load", ["src": path])
            #expect(Self.errorCode(refused) == AgentPaneReplyError.mediaRefused.rawValue, "\(path): \(refused)")
        }
        #expect(pane.images.all.isEmpty && pane.media.all.isEmpty)
        #expect(pane.effects.seen.isEmpty, "\(pane.effects.seen)")
        // A file opens in a tab only as one WebKit does not run as a page (never by its own handler).
        #expect(!AgentPaneFileOpen.showsInTab(page) && !AgentPaneFileOpen.showsInTab(drawing))
        #expect(AgentPaneFileOpen.showsInTab(clip) && AgentPaneFileOpen.showsInTab(shot))
    }

    /// An SVG naming every way it could act: links to app and web URLs, script, handlers, foreign
    /// content, a stylesheet instruction, animations that set a link, and `url(…)` references.
    private static let hostileSVG = """
        <?xml version="1.0"?><?xml-stylesheet href="cmux://workspace/ws_x"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" onload="location='cmux://workspace/ws_x'">
        <defs><linearGradient id="g"/></defs>
        <a href="cmux://workspace/ws_0123456789abcdef0123456789abcdef"><rect width="10" height="10" onclick="go()"/></a>
        <a xlink:href="cmux-dev-tag://session/abc" target="_top"><text>open</text></a>
        <svg:a xmlns:svg="http://www.w3.org/2000/svg" href="#local"><circle r="1"/></svg:a>
        <use href="cmux://tab/x"/><use xlink:href="#g"/>
        <image href="cmux://pane/x"/><image xlink:href="https://evil.example/p.png"/>
        <foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><a href="cmux://agent/x">x</a></div></foreignObject>
        <script>location='cmux://workspace/x'</script>
        <rect style="fill:url(cmux://x)" marker-start="url(https://evil.example/m.svg#m)" fill="url(#g)" ONMOUSEOVER="go()"/>
        <style>@import url(cmux://x); rect{fill:url(https://evil.example/x)}</style>
        <animate attributeName="href" to="cmux://workspace/x"/><set attributeName="href" to="cmux://x"/>
        </svg>
        """

    @Test func anSVGIsRebuiltWithNoLinkScriptHandlerOrOutsideReference() throws {
        let clean = try #require(AgentPaneSVGSanitizer.sanitize(Data(Self.hostileSVG.utf8)))
        let text = String(decoding: clean, as: UTF8.self)
        for gone in ["cmux", "evil.example", "<a ", "<a>", "<svg:a", "</a>", "</svg:a>", "onload", "onclick", "ONMOUSEOVER",
                     "foreignObject", "<script", "@import", "<set", "<animate ", "xml-stylesheet", "target="] {
            #expect(!text.contains(gone), "\(gone) in \(text)")
        }
        // What only draws stays: the shapes (a link's content is kept as a group), fragment references.
        for kept in ["<rect", "<circle", "<text>open</text>", "<g", "url(#g)", ##"xlink:href="#g""##] {
            #expect(text.contains(kept), "\(kept) missing from \(text)")
        }
        // The result is still one well-formed SVG.
        #expect(AgentPaneSVGSanitizer.sanitize(clean) != nil)
    }

    @Test func theImageViewerKeepsAnSVGOnlyAsItsRebuiltCopy() async throws {
        let pane = try Self.pane()
        let src = "data:image/svg+xml;base64," + Data(Self.hostileSVG.utf8).base64EncodedString()
        for method in ["image.reveal", "image.save", "image.quickLook"] {
            let reply = await Self.ask(pane, method, ["src": src, "name": "drawing"], click: true)
            #expect(Self.errorCode(reply) == nil, "\(method): \(reply)")
        }
        let files = pane.effects.seen.compactMap { $0.split(separator: " ", maxSplits: 1).last.map(String.init) }
        #expect(files.count == 3)
        for file in Set(files) {
            #expect(file.hasSuffix(".svg"))
            let written = String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
            for gone in ["cmux", "evil.example", "onload", "<script", "foreignObject", "<a "] {
                #expect(!written.contains(gone), "\(gone) in the copy \(file)")
            }
        }
        // An SVG the rebuild cannot read is not copied at all.
        let broken = "data:image/svg+xml;base64," + Data("<svg><a href='cmux://x'>".utf8).base64EncodedString()
        let refused = await Self.ask(pane, "image.save", ["src": broken, "name": "broken"], click: true)
        #expect(Self.errorCode(refused) != nil)
        #expect(pane.effects.seen.count == 3)
    }

    @Test func aCSSReferenceSpelledWithAnEscapeOrSplitByTheParserIsDroppedToo() throws {
        let svg = #"""
            <svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g"/></defs>
            <rect style="fill:u\72l(https://a.example/s.svg#p)" mask="u\rl(https://a.example/m.svg#m)"/>
            <rect fill="-webkit-image-set('https://a.example/i.png' 1x)"/>
            <style>rect{fill:\75 rl(https://a.example/t.svg#p)}</style>
            <style>rect{fill:&#117;rl(https://a.example/e.svg#p)}</style>
            <style>@im\70 ort 'https://a.example/i.css';</style>
            <style><b/>rect{fill:url(https://a.example/c.svg#p)}</style>
            <circle r="1" fill="url(#g)"/></svg>
            """#
        let text = String(decoding: try #require(AgentPaneSVGSanitizer.sanitize(Data(svg.utf8))), as: UTF8.self)
        #expect(!text.contains("a.example") && !text.contains("\\"), "\(text)")
        #expect(text.contains("<circle") && text.contains("url(#g)"), "\(text)")
    }

    @Test func aForeignElementOrABaseURIIsDroppedToo() throws {
        let svg = #"""
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:x="http://www.w3.org/1999/xlink"
             xml:base="https://a.example/" xml:space="preserve">
            <h:img src="https://a.example/i.png"/><g xmlns="http://www.w3.org/1999/xhtml"><img src="https://a.example/j.png"/></g>
            <q:rect xmlns:q="http://www.w3.org/2000/svg" width="2" height="2"/><use x:href="#r" xml:base="https://a.example/u/"/>
            <rect id="r" width="1" height="1"/></svg>
            """#
        let clean = try #require(AgentPaneSVGSanitizer.sanitize(Data(svg.utf8)))
        let text = String(decoding: clean, as: UTF8.self)
        for gone in ["a.example", "<img", "<h:", "<q:", "xml:base", "1999/xhtml"] {
            #expect(!text.contains(gone), "\(gone) in \(text)")
        }
        for kept in [#"<rect height="2" width="2""#, #"<rect height="1" id="r""#, ##"xlink:href="#r""##, #"xml:space="preserve""#,
                     #"xmlns="http://www.w3.org/2000/svg""#] {
            #expect(text.contains(kept), "\(kept) missing from \(text)")
        }
        #expect(AgentPaneSVGSanitizer.sanitize(clean) != nil)
    }

    @Test func aProjectSVGIsRebuiltOnlyFromARegularFileAndAnSVGZGoesOutAsOnBase() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real.svg"), link = folder.appendingPathComponent("link.svg")
        let pipe = folder.appendingPathComponent("pipe.svg"), out = folder.appendingPathComponent("out/copy.svg")
        try Data(Self.hostileSVG.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let fromFile = await AgentPaneImageCopies.rebuild(real, to: out)
        let fromLink = await AgentPaneImageCopies.rebuild(link, to: out)
        let fromPipe = await AgentPaneImageCopies.rebuild(pipe, to: out)
        #expect(fromFile && !fromLink && !fromPipe)
        let packed = folder.appendingPathComponent("drawing.svgz")
        #expect(AgentPaneImageCopies.handedOut(packed, in: folder) == packed)
        let copy = AgentPaneImageCopies.handedOut(URL(fileURLWithPath: "/project/a/drawing.svg"), in: folder)
        #expect(copy.deletingLastPathComponent().lastPathComponent.count == 32)
    }

    /// Whether `path` is a rebuilt copy in the pane's copies folder, with none of the SVG's links.
    private static func isRebuiltCopy(_ path: String, in pane: Pane) -> Bool {
        let folder = pane.model.replyLinks.imageFolder.resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(folder + "/"),
              let data = FileManager.default.contents(atPath: path) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("<rect") && !["cmux", "evil.example", "onload", "<script"].contains { text.contains($0) }
    }

    @Test(.timeLimit(.minutes(1))) func anSVGFileInTheProjectLeavesThePaneOnlyAsItsRebuiltCopy() async throws {
        let pane = try Self.pane()
        let svg = pane.project.appendingPathComponent("drawing.svg"), broken = pane.project.appendingPathComponent("broken.svg")
        let shot = pane.project.appendingPathComponent("shot.png"), page = pane.project.appendingPathComponent("index.html")
        try Data(Self.hostileSVG.utf8).write(to: svg)
        try Data("<svg><a href='cmux://x'>".utf8).write(to: broken)
        try Self.png.write(to: shot)
        try Data("<html></html>".utf8).write(to: page)
        let svgSource = "data:image/svg+xml;base64," + Data(Self.hostileSVG.utf8).base64EncodedString()

        // Show in Finder from the viewer: an SVG's copy, never the file the agent wrote; a PNG is still its own file.
        for (file, src) in [(svg, svgSource), (shot, "data:image/png;base64," + Self.png.base64EncodedString())] {
            let reply = await Self.ask(pane, "image.reveal", ["src": src, "name": file.lastPathComponent, "path": file.path], click: true)
            #expect(Self.errorCode(reply) == nil, "\(reply)")
        }
        // A path chip dragged out: the same; a broken SVG is refused.
        pane.model.replyLinks.mouseHeld = { true }
        for file in [svg, shot] { _ = await Self.ask(pane, "file.drag", ["path": file.path]) }
        let refused = await Self.ask(pane, "file.drag", ["path": broken.path])
        #expect(Self.errorCode(refused) != nil, "\(refused)")
        // A path chip's Save As…: the same file as the drag.
        let view = try #require(AgentPaneView(model: pane.model, source: .bundled(page)))
        for file in [svg, shot] {
            let save = try #require(view.pathMenuItems(file.path)?.first { $0.title == AgentPaneMenuStrings.saveAs })
            let saved = await withCheckedContinuation { (done: CheckedContinuation<URL, Never>) in
                pane.model.replyLinks.savePathFile = { file, _, _ in done.resume(returning: file) }
                _ = (save.target as? NSObject)?.perform(save.action, with: save)
            }
            pane.effects.seen.append("save \(saved.path)")
        }

        #expect(pane.effects.seen.count == 6, "\(pane.effects.seen)")
        for effect in pane.effects.seen {
            let path = String(effect.split(separator: " ", maxSplits: 1).last ?? "")
            if path.hasSuffix(".png") {
                #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == shot.resolvingSymlinksInPath(), "\(effect)")
            } else {
                #expect(Self.isRebuiltCopy(path, in: pane), "\(effect) is not the rebuilt copy")
            }
        }
    }

    @Test func nothingInAReplyNavigatesThePaneOrReachesTheAppByItself() {
        let source = AgentPaneSource.bundled(URL(string: "cmux-agent://pane/index.html")!)
        let hostile = [
            "cmux://workspace/ws_0123456789abcdef0123456789abcdef", "cmux-dev-tag://session/abc", "https://example.com/",
            "file:///etc/passwd", "javascript:alert(1)", "data:image/svg+xml;base64,PHN2Zy8+", "vscode://file/x",
            "cmux-agent://pane/__media/0123.mp4", "cmux-agent://pane/other.html",
        ].compactMap(URL.init(string:))
        for url in hostile {
            // Not clicked (script, an SVG's onload, a meta refresh): cancelled in the main frame and in a frame.
            #expect(AgentPaneNavigation.decision(for: url, source: source, userClicked: false) == .cancel, "\(url)")
            #expect(AgentPaneNavigation.decision(for: url, source: source, userClicked: true, mainFrame: false) == .cancel, "\(url)")
        }
        for text in ["file:///etc/passwd", "javascript:alert(1)", "data:image/svg+xml;base64,PHN2Zy8+", "vscode://file/x",
                     "cmux://auth-callback", "cmux-agent://pane/__media/0123.mp4"] {
            let url = URL(string: text)!
            #expect(AgentPaneNavigation.decision(for: url, source: source, userClicked: true) == .cancel, "\(text)")
        }
        // Even a link WebKit calls clicked opens nothing without the person's own gesture.
        let gestures = AgentPaneUserGestures()
        var opened: [URL] = []
        for url in hostile {
            #expect(!AgentPaneNavigation.openOutside(url, gestures: gestures, open: { opened.append($0) },
                                                     openApp: { opened.append($0); return true }))
        }
        #expect(opened.isEmpty, "\(opened)")
    }
}
