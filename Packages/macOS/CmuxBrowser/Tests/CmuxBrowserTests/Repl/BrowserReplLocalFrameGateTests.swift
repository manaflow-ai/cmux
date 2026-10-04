import AppKit
import WebKit
import Testing

@testable import CmuxBrowser

/// A user's tab on a local page inside the session's directories can hold
/// child frames that show local files outside them (the page names them,
/// and the user's tab has no content rules). Whatever the domain policy,
/// the frame gate treats such a frame as a blocked one for the session's
/// reads, input and captures, as the driver does a main frame
/// (`localPageRefusal`).
@MainActor
@Suite("Frame gate: local files in a user's tab", .serialized)
struct BrowserReplLocalFrameGateTests {
    typealias Scratch = BrowserReplFileSandboxTests.Scratch

    /// `work/index.html` with two child frames: `work/inside.html` at
    /// (10, 10) and `outside/page.html` at (200, 10), each 100 x 80.
    @MainActor
    struct LocalPage {
        let scratch: Scratch
        let webView: WKWebView
        let frames: [BrowserReplFrame]

        func frame(containing path: String) -> BrowserReplFrame? {
            frames.dropFirst().first { $0.url.contains(path) }
        }

        static func load(_ scratch: Scratch) async throws -> LocalPage {
            try Data("<p>inside</p><input id=f>".utf8).write(to: URL(fileURLWithPath: scratch.root + "/inside.html"))
            try Data("<p>outside secret</p><input id=f>".utf8).write(to: URL(fileURLWithPath: scratch.outside + "/page.html"))
            try Data("<p>moved secret</p>".utf8).write(to: URL(fileURLWithPath: scratch.outside + "/moved.html"))
            let index = """
            <p>index</p>
            <iframe id=a src="inside.html" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
            <iframe id=b src="../outside/page.html" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>
            """
            try Data(index.utf8).write(to: URL(fileURLWithPath: scratch.root + "/index.html"))
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
            // The user's tab may hold a wider grant than the session's directories.
            webView.loadFileURL(URL(fileURLWithPath: scratch.root + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: scratch.base))
            let frames = try await FramePage.settle(webView) { frames in
                frames.count >= 3 && frames.allSatisfy { !$0.url.isEmpty && $0.url != "about:blank" }
            }
            return LocalPage(scratch: scratch, webView: webView, frames: frames)
        }
    }

    /// `work/index.html` with two child frames that each replace their file
    /// with a `data:` document showing it: `work/pivot.html` and
    /// `outside/pivot.html`. With `recording`, each navigation is recorded
    /// as cmux's navigation delegate records it.
    @MainActor
    struct PivotPage {
        let webView: WKWebView
        let frames: [BrowserReplFrame]
        let delegate: OpaquePage.Recorder

        func frame(showing text: String) -> BrowserReplFrame? {
            frames.dropFirst().first { ($0.url.removingPercentEncoding ?? $0.url).contains(text) }
        }

        static func load(_ scratch: Scratch, recording: Bool) async throws -> PivotPage {
            let pivot = { (text: String) in #"<script>location.href = "data:text/html,<p>"# + text + #"</p>"</script>"# }
            try Data(pivot("inside data").utf8).write(to: URL(fileURLWithPath: scratch.root + "/pivot.html"))
            try Data(pivot("outside data secret").utf8).write(to: URL(fileURLWithPath: scratch.outside + "/pivot.html"))
            let index = """
            <p>index</p>
            <iframe src="pivot.html"></iframe>
            <iframe src="../outside/pivot.html"></iframe>
            """
            try Data(index.utf8).write(to: URL(fileURLWithPath: scratch.root + "/pivots.html"))
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
            let delegate = OpaquePage.Recorder(recording: recording)
            webView.navigationDelegate = delegate
            webView.loadFileURL(URL(fileURLWithPath: scratch.root + "/pivots.html"), allowingReadAccessTo: URL(fileURLWithPath: scratch.base))
            let frames = try await FramePage.settle(webView) { frames in
                frames.count >= 3 && frames.dropFirst().allSatisfy { $0.url.hasPrefix("data:") }
            }
            return PivotPage(webView: webView, frames: frames, delegate: delegate)
        }
    }

    /// A gate with no domain policy that judges `webView` as a user's tab.
    static func gate(_ page: LocalPage) -> BrowserReplFrameGate {
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        let root = page.scratch.root
        gate.localDocumentRoots = { _ in [root] }
        return gate
    }

    @Test func aChildFrameShowingAFileOutsideTheRootsIsNotEvaluated() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let page = try await LocalPage.load(scratch)
        let gate = Self.gate(page)
        let read = "return document.body.innerText"
        let outside = try #require(page.frame(containing: "/outside/page.html"))
        let error = await BrowserReplFrameGateTests.error {
            try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: outside, contentWorld: .page)
        }
        #expect(error?.code == "blocked", "a frame showing a file outside the roots was read: \(String(describing: error))")
        let inside = try #require(page.frame(containing: "/work/inside.html"))
        let text = try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: inside, contentWorld: .page)
        #expect((text as? String)?.contains("inside") == true)
        let main = FramePage(webView: page.webView, frames: page.frames).main
        let index = try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: main, contentWorld: .page)
        #expect((index as? String)?.contains("index") == true)
    }

    /// A frame keeps its id when it navigates: one that moved from a file
    /// inside the roots to one outside must not be read through its old record.
    @Test func aChildFrameThatNavigatedOutsideTheRootsIsNotEvaluatedThroughItsOldRecord() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let page = try await LocalPage.load(scratch)
        let gate = Self.gate(page)
        let inside = try #require(page.frame(containing: "/work/inside.html"))
        _ = try await gate.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: inside, contentWorld: .page)
        let main = FramePage(webView: page.webView, frames: page.frames).main
        _ = try await page.webView.callAsyncJavaScript(
            "document.getElementById('a').src = '../outside/moved.html'; return true", arguments: [:], in: main.info, contentWorld: .page
        )
        _ = try await FramePage.settle(page.webView) { frames in frames.contains { $0.url.hasSuffix("/outside/moved.html") } }
        let error = await BrowserReplFrameGateTests.error {
            try await gate.callAsyncJavaScript("return document.body.innerText", arguments: [:], in: page.webView, frame: inside, contentWorld: .page)
        }
        #expect(error?.code == "blocked", "the moved frame was read: \(String(describing: error))")
    }

    /// Input that would reach the outside frame, and captures that would
    /// show it, are refused; a screenshot blanks its box instead.
    @Test func inputAndCapturesThatWouldReachAFileOutsideTheRootsAreRefused() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let page = try await LocalPage.load(scratch)
        let gate = Self.gate(page)
        let over = await BrowserReplFrameGateTests.error {
            try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames)
        }
        #expect(over?.code == "blocked", "a point over the outside frame was allowed")
        #expect(await BrowserReplFrameGateTests.error {
            try await gate.checkPointer(at: [CGPoint(x: 50, y: 50)], in: page.webView, frames: page.frames)
        } == nil)
        let pdf = await BrowserReplFrameGateTests.error { try gate.checkCapture(in: page.webView, frames: page.frames) }
        #expect(pdf?.code == "blocked", "a capture of the outside frame was allowed")

        // The session's own tabs keep the content rules instead; the gate
        // leaves them alone without a policy.
        let own = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        #expect(await BrowserReplFrameGateTests.error { try own.checkCapture(in: page.webView, frames: page.frames) } == nil)
    }

    /// A file outside the roots can replace itself with a `data:` document
    /// that shows its content: an opaque origin with no file URL. It is
    /// judged by the file that made it.
    @Test func aDataDocumentAFileOutsideTheRootsMadeIsNotEvaluated() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let page = try await PivotPage.load(scratch, recording: true)
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        let root = scratch.root
        gate.localDocumentRoots = { _ in [root] }
        let read = "return document.body.innerText"
        let outside = try #require(page.frame(showing: "outside data secret"))
        let error = await BrowserReplFrameGateTests.error {
            try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: outside, contentWorld: .page)
        }
        #expect(error?.code == "blocked", "a data: document a file outside the roots made was read: \(String(describing: error))")
        #expect(gate.blocked(page.frames, in: page.webView).contains { $0.frame.frameID == outside.frameID },
                "input and captures would not treat the outside file's data: document as blocked")
        let inside = try #require(page.frame(showing: "inside data"))
        let text = try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: inside, contentWorld: .page)
        #expect((text as? String)?.contains("inside data") == true)
    }

    /// With no record of who made an opaque document, it may be a local
    /// file's outside the roots: refused, as a locked policy refuses one.
    @Test func anOpaqueDocumentWhoseMakerIsUnknownIsRefusedInAUsersLocalTab() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let page = try await PivotPage.load(scratch, recording: false)
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        let root = scratch.root
        gate.localDocumentRoots = { _ in [root] }
        let outside = try #require(page.frame(showing: "outside data secret"))
        let error = await BrowserReplFrameGateTests.error {
            try await gate.callAsyncJavaScript("return document.body.innerText", arguments: [:], in: page.webView, frame: outside, contentWorld: .page)
        }
        #expect(error?.code == "blocked", "an opaque document of unknown maker was read in a user's local tab: \(String(describing: error))")
    }

    /// The driver judges the tree before a capture, but a frame can show a
    /// file outside the roots by the time the capture is taken. The capture
    /// mask judges the documents the capture shows by the gate, also with
    /// no domain policy: a PDF, which cannot blank a frame, is refused, and
    /// a screenshot is handed the frame to blank.
    @Test func aCaptureJudgesTheLocalDocumentsItShowsWithoutAPolicy() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let page = try await LocalPage.load(scratch)
        let gate = Self.gate(page)
        let outside = try #require(page.frame(containing: "/outside/page.html"))
        var captured = false
        let pdf = await BrowserReplFrameGateTests.error {
            try await BrowserReplCaptureMask(secretMasks: [], gate: gate, blockedChildFrames: .refuse)
                .run(in: page.webView, frames: { page.frames.map(\.info) }) { captured = true }
        }
        #expect(pdf?.code == "blocked", "a PDF of a frame showing a file outside the roots was allowed: \(String(describing: pdf))")
        #expect(!captured)
        let handed = try await BrowserReplCaptureMask(secretMasks: [], gate: gate, blockedChildFrames: .handToCapture)
            .run(in: page.webView, frames: { page.frames.map(\.info) }) { blockedChildFrames in blockedChildFrames }
        #expect(handed[outside.frameID] != nil, "the frame showing a file outside the roots was not handed to the screenshot: \(handed)")
        let inside = try #require(page.frame(containing: "/work/inside.html"))
        #expect(handed[inside.frameID] == nil)
    }
}
