import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// A locator click checks its target, and each parent frame's `<iframe>`,
/// before it asks the driver for the press; the page runs between that
/// check and the press. The driver checks again in the web content
/// process right before it sends the press (``BrowserReplPressTarget``),
/// so a page that changed the point meanwhile gets no press. These tests
/// load real pages in WebKit with the repository's page agent.
@MainActor
@Suite("Press target", .serialized)
struct BrowserReplPressTargetTests {
    private static let world = WKContentWorld.world(name: "cmux-press-target-tests")
    private static let agent = #"globalThis[Symbol.for("cmux.browserRepl.agent")]"#

    private static let page = """
        <body style="margin:0">
        <button id=t style="position:absolute;left:100px;top:100px;width:120px;height:40px">Target</button>
        <div id=cover style="position:absolute;left:0;top:0;width:400px;height:300px;z-index:5;display:none"></div>
        <iframe id=f style="position:absolute;left:0;top:150px;width:300px;height:140px;border:0" srcdoc="<body style=margin:0><button id=c style=position:absolute;left:40px;top:40px;width:100px;height:40px>Child</button></body>"></iframe>
        </body>
        """

    private struct Loaded {
        let webView: WKWebView
        let main: BrowserReplFrame
        let child: BrowserReplFrame
    }

    private static func load() async throws -> Loaded {
        let page = try await FramePage.load(html: page) { frames in
            frames.count >= 2 && frames.allSatisfy { !$0.url.isEmpty }
        }
        let main = try #require(page.frames.first)
        let child = try #require(page.frames.dropFirst().first)
        let bundle = try browserReplRepositoryBundle()
        let source = try #require(bundle.agentInstallSource)
        for frame in [main, child] {
            _ = try? await page.webView.evaluateJavaScript(source, in: frame.info, contentWorld: world)
        }
        // The child's document is loaded once its button exists.
        let ready = try await page.webView.callAsyncJavaScript(
            "return !!document.getElementById('c') && \(agent) !== undefined;",
            arguments: [:],
            in: child.info,
            contentWorld: world
        ) as? Bool
        try #require(ready == true, "the child frame or its page agent is missing")
        return Loaded(webView: page.webView, main: main, child: child)
    }

    /// The agent's handle of the element `selector` names in `frame`.
    private static func handle(_ selector: String, in frame: BrowserReplFrame, of webView: WKWebView) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            "return \(agent).handleFor(document.querySelector(selector));",
            arguments: ["selector": selector],
            in: frame.info,
            contentWorld: world
        )
        return try #require(value as? String)
    }

    private static func page(_ script: String, in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Runs the checks as the driver does, in each frame's agent world.
    private static func verify(_ target: BrowserReplPressTarget, in webView: WKWebView) async -> BrowserReplDriverError? {
        let frames = await BrowserReplFrame.readTree(of: webView)
        do {
            try await target.verify(frames: frames) { body, arguments, frame in
                try await webView.callAsyncJavaScript(body, arguments: arguments, in: frame.info, contentWorld: world)
            }
            return nil
        } catch let error as BrowserReplDriverError {
            return error
        } catch {
            return BrowserReplDriverError(code: "unexpected", message: "\(error)")
        }
    }

    @Test func aPressGoesOnlyWhileItsTargetIsStillAtThePoint() async throws {
        let loaded = try await Self.load()
        let handle = try await Self.handle("#t", in: loaded.main, of: loaded.webView)
        let press = CGPoint(x: 160, y: 120)
        let target = try #require(try BrowserReplPressTarget(
            expect: ["frameId": loaded.main.frameID, "handle": handle, "x": 160, "y": 120],
            press: press
        ))
        #expect(await Self.verify(target, in: loaded.webView) == nil)

        // The page puts another element over the point after the runtime's check.
        try await Self.page("document.getElementById('cover').style.display = 'block';", in: loaded.webView)
        let covered = await Self.verify(target, in: loaded.webView)
        #expect(covered?.code == "stale")
        #expect(covered?.message.contains("no press was sent") == true, "\(String(describing: covered))")
        #expect(covered?.message.contains("intercepts pointer events") == true, "\(String(describing: covered))")

        // The page replaces the target with a copy.
        try await Self.page(
            "document.getElementById('cover').style.display = 'none'; const t = document.getElementById('t'); t.replaceWith(t.cloneNode(true));",
            in: loaded.webView
        )
        let replaced = await Self.verify(target, in: loaded.webView)
        #expect(replaced?.code == "stale")
        #expect(replaced?.message.contains("no press was sent") == true, "\(String(describing: replaced))")
    }

    @Test func aPressInAFrameGoesOnlyWhileTheFramesIframeIsStillAtThePoint() async throws {
        let loaded = try await Self.load()
        let button = try await Self.handle("#c", in: loaded.child, of: loaded.webView)
        let iframe = try await Self.handle("#f", in: loaded.main, of: loaded.webView)
        // The child's point (90, 60) is the tab's (90, 210): the <iframe> is at (0, 150).
        let expect: [String: Any] = [
            "frameId": loaded.child.frameID, "handle": button, "x": 90, "y": 60,
            "owners": [["frameId": loaded.main.frameID, "handle": iframe, "x": 90, "y": 210]],
        ]
        let target = try #require(try BrowserReplPressTarget(expect: expect, press: CGPoint(x: 90, y: 210)))
        #expect(await Self.verify(target, in: loaded.webView) == nil)

        // The page moves the <iframe> after the runtime's check: the press
        // point now holds something else of the main frame.
        try await Self.page("document.getElementById('f').style.left = '120px';", in: loaded.webView)
        let moved = await Self.verify(target, in: loaded.webView)
        #expect(moved?.code == "stale")
        #expect(moved?.message.contains("no press was sent") == true, "\(String(describing: moved))")

        // Back in place, with the main frame's element over the <iframe>.
        try await Self.page(
            "document.getElementById('f').style.left = '0px'; const c = document.getElementById('cover'); c.style.display = 'block';",
            in: loaded.webView
        )
        let covered = await Self.verify(target, in: loaded.webView)
        #expect(covered?.message.contains("intercepts pointer events") == true, "\(String(describing: covered))")
    }

    @Test func anExpectationThatDoesNotDescribeThePressIsRefused() async throws {
        let loaded = try await Self.load()
        let button = try await Self.handle("#c", in: loaded.child, of: loaded.webView)
        // It must end at the press point.
        #expect(throws: BrowserReplDriverError.self) {
            _ = try BrowserReplPressTarget(expect: ["handle": "h1.x", "x": 1, "y": 2], press: CGPoint(x: 1, y: 3))
        }
        #expect(throws: BrowserReplDriverError.self) {
            _ = try BrowserReplPressTarget(expect: ["x": 1, "y": 2], press: CGPoint(x: 1, y: 2))
        }
        #expect(try BrowserReplPressTarget(expect: nil, press: .zero) == nil)

        // A child frame's target with no owner <iframe> would skip the
        // check of where the frame is in the tab.
        let unowned = try #require(try BrowserReplPressTarget(
            expect: ["frameId": loaded.child.frameID, "handle": button, "x": 90, "y": 60],
            press: CGPoint(x: 90, y: 60)
        ))
        let error = await Self.verify(unowned, in: loaded.webView)
        #expect(error?.code == "stale")
        #expect(error?.message.contains("no press was sent") == true, "\(String(describing: error))")

        // A frame that no longer exists.
        let detached = try #require(try BrowserReplPressTarget(
            expect: ["frameId": "999999", "handle": button, "x": 90, "y": 60],
            press: CGPoint(x: 90, y: 60)
        ))
        #expect(await Self.verify(detached, in: loaded.webView)?.code == "stale")
    }
}
