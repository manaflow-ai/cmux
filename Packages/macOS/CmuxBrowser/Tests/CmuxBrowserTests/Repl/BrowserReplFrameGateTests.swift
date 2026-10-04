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

    // MARK: Reads, input and captures

    /// `frame.evaluate` and every other script the driver runs for the
    /// session in a frame: a frame that shows a blocked page is not read.
    @Test func aFrameThatShowsABlockedPageIsNotEvaluated() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let read = "return document.body.innerText"
        let error = await Self.error {
            try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: blocked, contentWorld: .page)
        }
        #expect(error?.code == "blocked", "a frame on a blocked domain was read: \(String(describing: error))")
        let allowed = try #require(page.frame(path: "/child"))
        let text = try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: allowed, contentWorld: .page)
        #expect((text as? String)?.contains("allowed.test/child") == true)
    }

    /// A frame keeps its id when it navigates, and the driver looks frames up
    /// by id from an earlier tree read: a frame that moved to a blocked page
    /// since must not be read through the old record, and the script must
    /// not run there at all.
    @Test func aFrameThatNavigatedToABlockedPageIsNotEvaluatedThroughItsOldRecord() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let child = try #require(page.frame(path: "/child"))
        _ = try await gate.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: child, contentWorld: .page)
        _ = try await page.run("document.getElementById('a').src = 'cmux-test://blocked.test/moved'; return true", in: page.main)
        _ = try await FramePage.settle(page.webView) { frames in
            frames.contains { $0.url == "cmux-test://blocked.test/moved" }
        }
        let error = await Self.error {
            try await gate.callAsyncJavaScript(
                "window.__ranByGate = true; return document.body.innerText",
                arguments: [:],
                in: page.webView,
                frame: child,
                contentWorld: .page
            )
        }
        #expect(error?.code == "blocked", "the moved frame was read: \(String(describing: error))")
        let ran = try await page.run("return window.__ranByGate === true", in: child)
        #expect(ran as? Bool == false, "the script ran in the blocked document")
    }

    /// Mouse input at a point over a blocked frame would reach it; points
    /// elsewhere on the page are fine.
    @Test func pointerInputOverAFrameThatShowsABlockedPageIsRefused() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let over = await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames) }
        #expect(over?.code == "blocked", "a point over the blocked frame was allowed")
        let path = await Self.error {
            try await gate.checkPointer(at: [CGPoint(x: 50, y: 50), CGPoint(x: 240, y: 30)], in: page.webView, frames: page.frames)
        }
        #expect(path?.code == "blocked", "a drag ending over the blocked frame was allowed")
        #expect(await Self.error { try await gate.checkPointer(at: [CGPoint(x: 50, y: 50)], in: page.webView, frames: page.frames) } == nil)
        #expect(await Self.error { try await gate.checkPointer(at: [CGPoint(x: 350, y: 250)], in: page.webView, frames: page.frames) } == nil)
    }

    /// Keys and inserted text go to the focused frame.
    @Test func keyboardInputWhileABlockedFrameHasTheFocusIsRefused() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let allowed = try #require(page.frame(path: "/child"))
        #expect(await Self.error { try await gate.checkFocus(in: page.webView, frames: page.frames) } == nil)
        _ = try await page.run("document.getElementById('f').focus(); return document.activeElement.id", in: blocked)
        let error = await Self.error { try await gate.checkFocus(in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "typing into the blocked frame's field was allowed")
        _ = try await page.run("document.getElementById('f').focus(); return document.activeElement.id", in: allowed)
        #expect(await Self.error { try await gate.checkFocus(in: page.webView, frames: page.frames) } == nil,
                "focus moved to the allowed frame, yet typing was refused")
    }

    /// A screenshot or PDF of the tab would show the blocked frame.
    @Test func capturesOfATabThatShowsABlockedFrameAreRefused() async throws {
        let page = try await FramePage.load()
        let error = await Self.error { try Self.gate().checkCapture(in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "a capture of the blocked frame was allowed")
        let unrelated = Self.gate(prohibiting: "cmux-test://other.test")
        #expect(await Self.error { try unrelated.checkCapture(in: page.webView, frames: page.frames) } == nil)
    }

    /// A blocked frame (an ad or tracker iframe under `allowedDomains`) must
    /// not refuse every capture of the tab: the capture blanks that frame's
    /// box and shows the rest of the page.
    @Test func aScreenshotBlanksABlockedFrameAndShowsTheRest() async throws {
        let page = try await FramePage.load()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let allowed = try #require(page.frame(path: "/child"))
        _ = try await page.run("document.body.style.background = 'rgb(255, 0, 0)'; return true", in: blocked)
        _ = try await page.run("document.body.style.background = 'rgb(0, 255, 0)'; return true", in: allowed)
        let gate = Self.gate()
        let image = try await gate.coverBlockedFrames(in: page.webView, frames: { await BrowserReplFrame.readTree(of: page.webView) }) {
            (try await FramePage.viewportImage(of: page.webView), CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let blockedPixel = try #require(FramePage.pixel(image, x: 250, y: 50))
        #expect(!(blockedPixel.red > 0.8 && blockedPixel.green < 0.2), "the blocked frame's content is in the capture")
        let allowedPixel = try #require(FramePage.pixel(image, x: 60, y: 50))
        #expect(allowedPixel.green > 0.8 && allowedPixel.red < 0.2, "the allowed frame was blanked too")
    }

    /// Blanking a box hides a frame only when nothing draws its content
    /// elsewhere; a reflection does, so the capture is refused.
    @Test func aScreenshotOfABlockedFrameDrawnOutsideItsBoxIsRefused() async throws {
        let page = try await FramePage.load()
        _ = try await page.run("document.getElementById('b').style.webkitBoxReflect = 'below 0px'; return true", in: page.main)
        let gate = Self.gate()
        let error = await Self.error {
            try await gate.coverBlockedFrames(in: page.webView, frames: { await BrowserReplFrame.readTree(of: page.webView) }) {
                (try await FramePage.viewportImage(of: page.webView), CGRect(x: 0, y: 0, width: 400, height: 300))
            }
        }
        #expect(error?.code == "blocked", "a capture of a reflected blocked frame was allowed")
    }

    /// A file chooser is answered with files only when its own frame is
    /// allowed; another frame of the tab that shows a blocked page does not
    /// matter.
    @Test func aFileChooserIsJudgedByItsOwnFrame() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test")?.info)
        let allowed = try #require(page.frame(path: "/child")?.info)
        #expect(await Self.error { try await gate.checkFileChooser(frame: allowed, in: page.webView, frames: page.frames) } == nil,
                "a chooser in an allowed frame was refused because another frame is blocked")
        let error = await Self.error { try await gate.checkFileChooser(frame: blocked, in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "files were given to a chooser in a blocked frame")
    }

    /// `window.frames` leaves out frames in shadow trees, so a child's index
    /// in WebKit's frame tree is not its index there. A blocked frame in a
    /// shadow tree must still refuse a point over it.
    @Test func pointerInputOverABlockedFrameInAShadowTreeIsRefused() async throws {
        let html = """
            <iframe id=a src="cmux-test://allowed.test/child" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
            <div id=host></div>
            <script>
            const root = document.getElementById('host').attachShadow({ mode: 'closed' });
            root.innerHTML = '<iframe src="cmux-test://blocked.test/x" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>';
            </script>
            <iframe id=c src="cmux-test://allowed.test/other" style="position:absolute;left:10px;top:150px;width:100px;height:80px;border:0"></iframe>
            """
        let page = try await FramePage.load(html: html) { frames in frames.count >= 4 && frames.allSatisfy { !$0.url.isEmpty } }
        let gate = Self.gate()
        let over = await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames) }
        #expect(over?.code == "blocked", "a point over a blocked frame in a shadow tree was allowed")
    }

    /// In a tab the session created the policy's content rules stop a
    /// blocked frame from loading; the empty frame left behind is the
    /// parent's and does not refuse the tab.
    @Test func aFrameTheContentRulesKeptFromLoadingDoesNotRefuseTheTab() async throws {
        let gate = Self.gate()
        let rules = String(decoding: try JSONSerialization.data(withJSONObject: gate.policy.contentRules), as: UTF8.self)
        let store = try #require(WKContentRuleListStore.default())
        let identifier = "cmux-frame-gate-tests-\(UUID().uuidString)"
        let list = try #require(try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules))
        defer { store.removeContentRuleList(forIdentifier: identifier) { _ in } }
        // The blocked frame never gets a URL; the allowed one loads.
        let page = try await FramePage.load(loaded: { frames in frames.contains { $0.url.hasSuffix("/child") } }) { configuration in
            configuration.userContentController.add(list)
        }
        #expect(page.frame(host: "blocked.test") == nil, "the content rules let the blocked frame load")
        #expect(await Self.error { try gate.checkCapture(in: page.webView, frames: page.frames) } == nil)
        #expect(await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames) } == nil)
    }

    // MARK: Probes that never answer

    /// The gate's own probes (the focus probe, the frame boxes, a frame's
    /// document) are bounded: one that does not answer refuses the call
    /// with `stale` instead of hanging every later input call.
    @Test func aProbeThatNeverAnswersRefusesWithStale() async throws {
        let page = try await FramePage.load()
        // The page's web process runs no other script for 25 s, so the
        // gate's probes of any frame in it do not answer (as when a
        // navigation replaces the document and WebKit drops the completion).
        page.webView.evaluateJavaScript("{ const end = Date.now() + 25000; while (Date.now() < end) {} }", completionHandler: nil)
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let webView = SendableBox(page.webView)
        let frames = SendableBox(page.frames)
        let focus = await browserReplWithDeadline(seconds: 30) { @MainActor in
            await Self.error { try await gate.checkFocus(in: webView.value, frames: frames.value) }
        }
        #expect(focus??.code == "stale", "the focus probe of a frame that does not answer hung or passed: \(String(describing: focus))")
        let pointer = await browserReplWithDeadline(seconds: 30) { @MainActor in
            await Self.error { try await gate.checkPointer(at: [CGPoint(x: 50, y: 50)], in: webView.value, frames: frames.value) }
        }
        #expect(pointer??.code == "stale", "the frame-box probe of a page that does not answer hung or passed: \(String(describing: pointer))")
        let frame = SendableBox(blocked)
        let document = await browserReplWithDeadline(seconds: 30) { @MainActor in
            await Self.error { try await gate.authorize(frame.value, in: webView.value) }
        }
        #expect(document??.code == "stale", "the document probe of a frame that does not answer hung or passed: \(String(describing: document))")
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

    /// The viewport as an image of one pixel per CSS pixel.
    static func viewportImage(of webView: WKWebView) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        let image = try await webView.takeSnapshot(configuration: configuration)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw BrowserReplDriverError(code: "invalid", message: "the snapshot had no bitmap")
        }
        return cgImage
    }

    /// The color at CSS pixel (`x`, `y`) from the top-left of `image`, which
    /// shows a 400-point-wide viewport.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(bitmap.pixelsWide) / 400
        guard let color = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB) else {
            return nil
        }
        return (color.redComponent, color.greenComponent, color.blueComponent)
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

/// Hands main-actor test values to a `@Sendable` closure that runs on the
/// main actor.
struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
