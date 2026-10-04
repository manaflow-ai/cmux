import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// The frame gate decides which frames are blocked from a tree read before
/// guarded input or a capture, then holds those frames out of reach while it
/// is in flight. The page keeps running meanwhile: it can take the guard off,
/// move a blocked frame over other content and back, or create a frame (or
/// navigate an allowed one) to a blocked page. None of that may hand the
/// input to a blocked frame or put one in the capture.
@MainActor
@Suite("Guarded input and capture windows", .serialized)
struct BrowserReplGuardWindowTests {
    private static func gate(_ hold: BrowserReplSubframeLoadHold) -> BrowserReplFrameGate {
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world, loadHold: hold)
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try! BrowserReplDomainPattern.parse("cmux-test://blocked.test", title: "test")]
        gate.policy = policy
        return gate
    }

    /// The app's navigation delegate as far as the hold goes: it answers a
    /// navigation the hold holds back once the hold comes off.
    private final class Delegate: NSObject, WKNavigationDelegate {
        let hold: BrowserReplSubframeLoadHold
        var asked: [String] = []

        init(hold: BrowserReplSubframeLoadHold) {
            self.hold = hold
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            asked.append(navigationAction.request.url?.absoluteString ?? "")
            if hold.holdsBack(navigationAction.targetFrame, in: webView, until: { decisionHandler(.allow) }) { return }
            decisionHandler(.allow)
        }
    }

    /// Once WebKit asked about `url`: `held` while its load waits for the
    /// hold, `loaded` once a frame shows it.
    private static func fate(of url: String, in page: FramePage, delegate: Delegate, hold: BrowserReplSubframeLoadHold) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if await BrowserReplFrame.readTree(of: page.webView).contains(where: { $0.url == url }) { return "loaded" }
            if delegate.asked.contains(url), hold.waitingCount(page.webView) > 0 { return "held" }
            try await Task.sleep(for: .milliseconds(20))
        }
        return "neither"
    }

    // MARK: Input

    @Test("A frame the page creates or navigates to a blocked page while input is in flight loads it only after the input",
          arguments: ["create", "navigate"])
    func framesLoadNoNewDocumentDuringInput(_ how: String) async throws {
        let page = try await FramePage.load()
        let hold = BrowserReplSubframeLoadHold()
        let delegate = Delegate(hold: hold)
        page.webView.navigationDelegate = delegate
        defer { page.webView.navigationDelegate = nil }
        let gate = Self.gate(hold)
        let url = "cmux-test://blocked.test/late"
        let change = how == "create"
            ? "const f = document.createElement('iframe'); f.src = '\(url)'; f.style.cssText = 'position:absolute;left:10px;top:110px;width:100px;height:80px;border:0'; document.body.append(f); return true"
            : "document.getElementById('a').src = '\(url)'; return true"
        let webView = page.webView
        let during = try await gate.guardingInput(in: webView, frames: { await BrowserReplFrame.readTree(of: webView) }, checkFocusAfter: false) {
            _ = try await page.run(change, in: page.main)
            return try await Self.fate(of: url, in: page, delegate: delegate, hold: hold)
        }
        #expect(during == "held", "the blocked page loaded into a frame while input was in flight (\(during))")
        let after = try await Self.fate(of: url, in: page, delegate: delegate, hold: hold)
        #expect(after == "loaded", "the held load did not go on after the input (\(after))")
    }

    @Test("A page that takes the guard off a blocked frame during the input does not get the input to it")
    func removedGuardIsPutBackBeforeTheNextEvent() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate(BrowserReplSubframeLoadHold())
        let webView = page.webView
        var hit: String?
        let error = await BrowserReplFrameGateTests.error {
            try await gate.guardingInput(in: webView, frames: { await BrowserReplFrame.readTree(of: webView) }, checkFocusAfter: false) {
                _ = try await page.run(#"document.getElementById("b").removeAttribute("inert"); return true"#, in: page.main)
                // The next event the page handles, as a later input would be.
                hit = try await page.run(#"const e = document.elementFromPoint(250, 50); return e ? e.id || e.tagName : null"#, in: page.main) as? String
                return true
            }
        }
        #expect(hit != "b", "the blocked frame was hit after the page took its guard off")
        #expect(error?.code == "blocked", "the input went on after the page took the guard off: \(String(describing: error))")
    }

    // MARK: Capture

    @Test("A blocked frame the page moves over other content during the capture, and back, is not in it")
    func aBlockedFrameMovedDuringTheCaptureIsNotInIt() async throws {
        let page = try await FramePage.load()
        let blocked = try #require(page.frame(host: "blocked.test"))
        _ = try await page.run("document.body.style.background = 'rgb(255, 0, 0)'; return true", in: blocked)
        _ = try await page.run("document.body.style.background = 'rgb(0, 0, 255)'; return true", in: page.main)
        let gate = Self.gate(BrowserReplSubframeLoadHold())
        let move = { (left: Int, top: Int) in
            "const b = document.getElementById('b'); b.style.left = '\(left)px'; b.style.top = '\(top)px'; return true"
        }
        let image = try await gate.coverBlockedFrames(in: page.webView, frames: { await BrowserReplFrame.readTree(of: page.webView) }) {
            _ = try await page.run(move(10, 110), in: page.main)
            let image = try await FramePage.viewportImage(of: page.webView)
            _ = try await page.run(move(200, 10), in: page.main)
            return (image, CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let moved = try #require(FramePage.pixel(image, x: 50, y: 150))
        #expect(!(moved.red > 0.8 && moved.blue < 0.2), "the blocked frame's content is in the capture where the page moved it")
    }

    @Test("A frame the page creates with a blocked page during the capture, and removes, is not in it")
    func aFrameCreatedDuringTheCaptureIsNotInIt() async throws {
        let page = try await FramePage.load()
        _ = try await page.run("document.body.style.background = 'rgb(0, 0, 255)'; return true", in: page.main)
        let hold = BrowserReplSubframeLoadHold()
        let delegate = Delegate(hold: hold)
        page.webView.navigationDelegate = delegate
        defer { page.webView.navigationDelegate = nil }
        let gate = Self.gate(hold)
        let url = "cmux-test://blocked.test/transient"
        var fate = ""
        let image = try await gate.coverBlockedFrames(in: page.webView, frames: { await BrowserReplFrame.readTree(of: page.webView) }) {
            _ = try await page.run(
                "const f = document.createElement('iframe'); f.id = 't'; f.src = '\(url)'; f.style.cssText = 'position:absolute;left:10px;top:110px;width:100px;height:80px;border:0;background:transparent'; document.body.append(f); return true",
                in: page.main
            )
            fate = try await Self.fate(of: url, in: page, delegate: delegate, hold: hold)
            let image = try await FramePage.viewportImage(of: page.webView)
            _ = try await page.run("document.getElementById('t').remove(); return true", in: page.main)
            return (image, CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        // The blocked page's text is dark; the main page under the frame is blue.
        var dark = 0
        for y in stride(from: 112, to: 188, by: 2) {
            for x in stride(from: 12, to: 108, by: 2) {
                if let pixel = FramePage.pixel(image, x: x, y: y), pixel.red < 0.4, pixel.green < 0.4, pixel.blue < 0.4 { dark += 1 }
            }
        }
        #expect(dark == 0, "the blocked page's text is in the capture (\(fate))")
        #expect(fate == "held", "the blocked page loaded into a frame during the capture (\(fate))")
    }
}
