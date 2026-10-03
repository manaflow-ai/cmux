import AppKit
import WebKit
import Testing

@testable import CmuxBrowser

/// The domain policy applies to every frame of a tab, not only the main
/// frame: a page the policy allows can embed a frame that shows a page it
/// blocks (a user's tab has no content rules, and a frame can load before
/// the policy is set). These tests load real pages in WebKit, served by a
/// scheme handler for `cmux-test://allowed.test` and `cmux-test://blocked.test`.
@MainActor
@Suite("Frame gate", .serialized)
struct BrowserReplFrameGateTests {
    // MARK: auth.request

    /// `auth.request` fills credentials into one frame; the gate must refuse
    /// a frame that shows a blocked page, whatever the main frame shows.
    @Test func authorizeRefusesAFrameThatShowsABlockedPage() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let error = await Self.error { try await gate.authorize(blocked, in: page.webView) }
        #expect(error?.code == "blocked", "a frame on a blocked domain was authorized")
        let allowed = try #require(page.frame(path: "/child"))
        #expect(await Self.error { try await gate.authorize(allowed, in: page.webView) } == nil)
        #expect(await Self.error { try await gate.authorize(page.main, in: page.webView) } == nil)
    }

    @Test func authorizeRefusesAMainFrameThatShowsABlockedPage() async throws {
        let page = try await FramePage.load(url: "cmux-test://blocked.test/")
        let gate = Self.gate()
        let error = await Self.error { try await gate.authorize(page.main, in: page.webView) }
        #expect(error?.code == "blocked", "a main frame on a blocked domain was authorized")
    }

    // MARK: Support

    static let world = WKContentWorld.world(name: "cmux-frame-gate-tests")

    static func gate(prohibiting pattern: String = "cmux-test://blocked.test") -> BrowserReplFrameGate {
        let gate = BrowserReplFrameGate(world: world)
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try! BrowserReplDomainPattern.parse(pattern, title: "test")]
        gate.policy = policy
        return gate
    }

    static func error(_ body: () async throws -> Any?) async -> BrowserReplDriverError? {
        do {
            _ = try await body()
            return nil
        } catch let error as BrowserReplDriverError {
            return error
        } catch {
            return BrowserReplDriverError(code: "unexpected", message: "\(error)")
        }
    }
}

/// A page with two child frames: `allowed.test/child` at (10, 10) and
/// `blocked.test/x` at (200, 10), each 100 x 80 and holding a text field.
@MainActor
struct FramePage {
    let webView: WKWebView
    let frames: [BrowserReplFrame]

    /// The main frame as the driver names it without a tree read.
    var main: BrowserReplFrame {
        BrowserReplFrame(frameID: "main", parentFrameID: nil, indexInParent: 0, info: nil,
                         url: webView.url?.absoluteString ?? "", name: "", crossOrigin: false)
    }

    func frame(host: String) -> BrowserReplFrame? {
        frames.dropFirst().first { URL(string: $0.url)?.host == host }
    }

    func frame(path: String) -> BrowserReplFrame? {
        frames.dropFirst().first { URL(string: $0.url)?.path == path }
    }

    static let mainPage = """
        <p>main</p>
        <iframe id=a src="cmux-test://allowed.test/child" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
        <iframe id=b src="cmux-test://blocked.test/x" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>
        """

    /// - Parameter loaded: when the page counts as loaded; by default once
    ///   every frame has a URL.
    static func load(
        url: String = "cmux-test://allowed.test/",
        html: String = mainPage,
        loaded: (([BrowserReplFrame]) -> Bool)? = nil,
        configure: (WKWebViewConfiguration) async throws -> Void = { _ in }
    ) async throws -> FramePage {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FramePageSchemeHandler(mainPage: html), forURLScheme: "cmux-test")
        try await configure(configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let expected = html == mainPage && url == "cmux-test://allowed.test/" ? 3 : 1
        webView.load(URLRequest(url: URL(string: url)!))
        let frames = try await settle(webView) { frames in
            frames.count >= expected && (loaded?(frames) ?? frames.allSatisfy { !$0.url.isEmpty })
        }
        return FramePage(webView: webView, frames: frames)
    }

    /// The frame tree once `done` holds for it (child frames load after the
    /// main frame).
    static func settle(_ webView: WKWebView, _ done: ([BrowserReplFrame]) -> Bool) async throws -> [BrowserReplFrame] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let frames = await BrowserReplFrame.readTree(of: webView)
            if done(frames) { return frames }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BrowserReplDriverError(code: "timeout", message: "the test page did not settle")
    }

    /// Runs `source` in `frame`'s page world without the gate.
    func run(_ source: String, in frame: BrowserReplFrame) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: frame.info, contentWorld: .page)
    }
}

final class FramePageSchemeHandler: NSObject, WKURLSchemeHandler {
    let mainPage: String

    init(mainPage: String) {
        self.mainPage = mainPage
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let host = url.host ?? ""
        let html = url.path == "/" || url.path.isEmpty
            ? mainPage
            : "<p>\(host)\(url.path)</p><input id=f>"
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        task.didReceive(Data(html.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
