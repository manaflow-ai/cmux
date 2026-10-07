import CmuxNextSettings
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextAgentPane

/// Reply images (D5) and the network rules of the host fetch.
@MainActor
@Suite struct AgentPaneReplyImageTests {
    /// A fetcher that records what it was asked and answers `data`.
    final class FakeFetch: AgentPaneImageFetching, @unchecked Sendable {
        var asked: [URL] = []
        let data: Data?
        init(_ data: Data?) { self.data = data }
        func fetch(_ url: URL) async -> Result<Data, AgentPaneReplyError> {
            asked.append(url)
            return data.map { .success($0) } ?? .failure(.imageFailed)
        }
    }

    static func png(width: Int = 4, height: Int = 3) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        if let image = context?.makeImage(), let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return output as Data
    }

    static func load(_ model: AgentPaneModel, _ src: String) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "image.load", "params": ["src": src]] as [String: Any]))
    }

    static func model(root: URL, _ setting: AgentPaneReplySetting = .fallback, fetch: FakeFetch = FakeFetch(nil)) -> AgentPaneModel {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let path = root.path
        model.workspaceRoots = { [path] }
        model.replyLinks.settings = { setting }
        model.replyLinks.fetcher = fetch
        return model
    }

    static func src(_ reply: [String: Any]) -> String? { (reply["value"] as? [String: Any])?["src"] as? String }

    @Test func aLocalImageInsideTheRootsLoadsAsADataURLAndNothingElseDoes() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "reply-images-\(UUID().uuidString)")
        let root = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.png().write(to: root.appending(path: "shot.png"))
        try Data("not an image".utf8).write(to: root.appending(path: "fake.png"))
        try Self.png().write(to: base.appending(path: "outside.png"))
        let model = Self.model(root: root)
        // No gesture needed for a file inside the project.
        #expect(Self.src(await Self.load(model, root.appending(path: "shot.png").path))?.hasPrefix("data:image/png;base64,") == true)
        #expect(Self.src(await Self.load(model, "shot.png"))?.hasPrefix("data:image/png;base64,") == true)
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, root.appending(path: "fake.png").path)) == "link.image_failed")
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, base.appending(path: "outside.png").path)) == "link.path_outside_roots")
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, "file:///etc/hosts")) == "link.path_outside_roots")
    }

    @Test func anSVGLosesScriptHandlersAndLinksOut() throws {
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" onload="alert(1)">
          <script>alert(2)</script>
          <foreignObject><div>x</div></foreignObject>
          <a xlink:href="https://evil.example/"><rect width="5" height="5" style="fill:url(https://evil.example/p)"/></a>
          <style>@import url(https://evil.example/a.css);</style><style>.a{fill:url(#grad)}</style>
          <use href="#shape"/><circle id="shape" r="2" fill="url(#grad)"/>
        </svg>
        """#
        let clean = try #require(AgentPaneSVGSanitizer.sanitize(Data(svg.utf8)).map { String(decoding: $0, as: UTF8.self) })
        for gone in ["onload", "script", "alert", "foreignObject", "evil.example"] { #expect(!clean.contains(gone), "\(gone)") }
        for kept in ["<circle", "href=\"#shape\"", "url(#grad)", "<rect", ".a{fill:url(#grad)}"] { #expect(clean.contains(kept), "\(kept)") }
        #expect(AgentPaneSVGSanitizer.sanitize(Data("<html><svg/></html>".utf8)) == nil)
    }

    @Test func aWebImageFollowsTheSetting() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = "https://images.example/cat.png"
        // never: no fetch at all.
        var fetch = FakeFetch(Self.png())
        var model = Self.model(root: root, AgentPaneReplySetting(outsideRoots: .confirm, remoteImages: .never), fetch: fetch)
        model.transport.gestures.record()
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, url)) == "link.image_refused")
        #expect(fetch.asked.isEmpty)
        // click (default): only after a gesture, and the bytes come back re-encoded as PNG.
        fetch = FakeFetch(Self.png(width: 3000, height: 10))
        model = Self.model(root: root, fetch: fetch)
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, url)) == "link.gesture_required")
        #expect(fetch.asked.isEmpty)
        model.transport.gestures.record()
        let loaded = try #require(Self.src(await Self.load(model, url)))
        #expect(loaded.hasPrefix("data:image/png;base64,"))
        let bytes = try #require(Data(base64Encoded: String(loaded.dropFirst("data:image/png;base64,".count))))
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == AgentPaneReplyImages.maximumSide)
        // always: no gesture, the same fetch.
        fetch = FakeFetch(Data("<html>".utf8))
        model = Self.model(root: root, AgentPaneReplySetting(outsideRoots: .confirm, remoteImages: .always), fetch: fetch)
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, url)) == "link.image_failed")
        #expect(fetch.asked == [URL(string: url)])
        // http is never fetched.
        model.transport.gestures.record()
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, "http://images.example/cat.png")) == "link.image_refused")
        #expect(fetch.asked.count == 1)
    }

    @Test func theFetchReachesOnlyPublicAddresses() async {
        for blocked in ["127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.1", "169.254.169.254", "100.89.225.106", "100.64.0.1",
                        "0.0.0.0", "224.0.0.1", "255.255.255.255", "::1", "::", "fe80::1", "fd7a:115c:a1e0::1", "fc00::1",
                        "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "2002:7f00:1::", "ff02::1", "2001:db8::1", "fe80::1%en0"] {
            #expect(!AgentPaneNetworkRules.isPublic(blocked), "\(blocked)")
        }
        for open in ["8.8.8.8", "1.1.1.1", "100.128.0.1", "2606:4700::1111", "::ffff:8.8.8.8", "64:ff9b::808:808"] {
            #expect(AgentPaneNetworkRules.isPublic(open), "\(open)")
        }
        #expect(await !AgentPaneNetworkRules.resolvesPublicly("localhost"))
        #expect(await !AgentPaneNetworkRules.resolvesPublicly("127.0.0.1"))
        #expect(await !AgentPaneNetworkRules.resolvesPublicly("[::1]"))
        // The fetch refuses before any network: not https, user info, a host that is not public.
        var fetch = AgentPaneSafeFetch()
        fetch.hostCheck = { _ in false }
        for text in ["http://example.com/a.png", "https://u:p@example.com/a.png", "https://example.com/a.png"] {
            let result = await fetch.fetch(URL(string: text)!)
            #expect(result == .failure(.imageRefused), "\(text)")
        }
        let configuration = AgentPaneSafeFetch.configuration()
        #expect(configuration.httpCookieStorage == nil && configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil && configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForResource == 10)
    }

    /// The preview card's "Open in" menu (D6): opaque ids from the host's own list, a gesture, and
    /// never an app the list did not give.
    @MainActor final class FakeBrowsers: AgentPaneBrowserApps {
        var opened: [(URL, URL)] = []
        func applications() -> [URL] {
            [URL(fileURLWithPath: "/Applications/Safari.app"), URL(fileURLWithPath: "/Applications/Firefox.app"),
             URL(fileURLWithPath: "/Applications/Safari.app")]
        }
        func displayName(of app: URL) -> String { app.deletingPathExtension().lastPathComponent }
        func iconPNG(of app: URL) -> Data? { Data([1, 2, 3]) }
        func open(_ url: URL, withApplicationAt app: URL) { opened.append((url, app)) }
    }

    @Test func openInOpensOnlyAListedBrowserForAWebURLAfterAGesture() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let browsers = FakeBrowsers()
        model.replyLinks.browsers = browsers
        var previews: [URL] = []
        model.onOpenPreview = { previews.append($0); return true }
        let list = await model.respond(to: AgentPaneRequest(body: ["method": "browser.list", "params": [:]] as [String: Any]))
        let entries = try #require((list["value"] as? [String: Any])?["browsers"] as? [[String: String]])
        #expect(entries.map { $0["name"] } == ["Safari", "Firefox"])
        #expect(entries.allSatisfy { $0["icon"]?.hasPrefix("data:image/png;base64,") == true })
        // The id is opaque: no path, no bundle id.
        #expect(entries.allSatisfy { !($0["id"] ?? "").contains("/") && !($0["id"] ?? "").contains("Safari") })
        let safari = try #require(entries.first?["id"])
        func openIn(_ id: String, _ url: String = "https://example.com/a?b=1") async -> [String: Any] {
            await model.respond(to: AgentPaneRequest(body: ["method": "browser.openIn", "params": ["url": url, "browserId": id]] as [String: Any]))
        }
        #expect(AgentPaneReplyLinkTests.code(await openIn(safari)) == "link.gesture_required")
        model.transport.gestures.record()
        #expect(AgentPaneReplyLinkTests.code(await openIn("/System/Applications/Utilities/Terminal.app")) == "link.browser_unknown")
        #expect(await openIn(safari)["ok"] as? Bool == true)
        #expect(browsers.opened.map(\.0.absoluteString) == ["https://example.com/a?b=1"])
        #expect(browsers.opened.map(\.1.path) == ["/Applications/Safari.app"])
        // cmux's own browser pane, also after a gesture.
        model.transport.gestures.record()
        #expect(await openIn("cmux")["ok"] as? Bool == true)
        #expect(previews.map(\.absoluteString) == ["https://example.com/a?b=1"])
        // A new list makes the old ids dead.
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "browser.list", "params": [:]] as [String: Any]))
        model.transport.gestures.record()
        #expect(AgentPaneReplyLinkTests.code(await openIn(safari)) == "link.browser_unknown")
    }
}

/// The fetch's own refusals, against a stub transport (no network): a redirect to a host that is
/// not public, a body over the cap, and a connection whose address is unknown or private.
@Suite struct AgentPaneSafeFetchTests {
    /// Serves `https://public.example/<path>` from a fixed table.
    nonisolated final class Stub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let client else { return }
            switch url.path {
            case "/redirect":
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://inside.example/x.png"])!
                client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://inside.example/x.png")!), redirectResponse: response)
            case "/big":
                client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                   cacheStoragePolicy: .notAllowed)
                let chunk = Data(count: 1 << 20)
                for _ in 0..<(AgentPaneSafeFetch.maximumBytes / chunk.count + 2) { client.urlProtocol(self, didLoad: chunk) }
                client.urlProtocolDidFinishLoading(self)
            default:
                client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                   cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: Data("ok".utf8))
                client.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }

    static func fetch(addresses: Bool = true) -> AgentPaneSafeFetch {
        var fetch = AgentPaneSafeFetch()
        fetch.hostCheck = { $0 == "public.example" }
        if addresses { fetch.addressesCheck = { _ in true } }
        fetch.makeConfiguration = {
            let configuration = AgentPaneSafeFetch.configuration()
            configuration.protocolClasses = [Stub.self]
            return configuration
        }
        return fetch
    }

    @Test func aRedirectToAHostThatIsNotPublicIsRefused() async {
        #expect(await Self.fetch().fetch(URL(string: "https://public.example/redirect")!) == .failure(.imageRefused))
    }

    @Test func aBodyOverTheCapIsRefused() async {
        #expect(await Self.fetch().fetch(URL(string: "https://public.example/big")!) == .failure(.imageTooLarge))
    }

    @Test func aConnectionWhoseAddressIsUnknownOrPrivateDropsTheBody() async {
        // The stub has no socket, so no transaction reports an address: refused (fail closed).
        #expect(await Self.fetch(addresses: false).fetch(URL(string: "https://public.example/ok")!) == .failure(.imageRefused))
        #expect(await Self.fetch().fetch(URL(string: "https://public.example/ok")!) == .success(Data("ok".utf8)))
        var check = AgentPaneSafeFetch().addressesCheck
        #expect(!check([]) && !check([nil]) && !check(["8.8.8.8", "10.0.0.2"]) && check(["8.8.8.8", "2606:4700::1111"]))
        check = Self.fetch().addressesCheck
        #expect(check([nil]))
    }
}
