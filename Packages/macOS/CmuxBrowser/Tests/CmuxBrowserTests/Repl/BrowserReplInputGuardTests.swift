import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// Trusted input is sent as a point or a key for the whole tab, after the
/// gate checked that no blocked frame is under the point or holds the
/// focus. The page can move a blocked frame under the point, or the focus
/// into it, between that check and the input. While the input is in
/// flight, the gate makes every blocked frame's element `inert` (not hit
/// tested, not focusable, wherever it moves), and fails the input with
/// `blocked` when the page undid that meanwhile.
@MainActor
@Suite("Input guard", .serialized)
struct BrowserReplInputGuardTests {
    /// What the main frame hit-tests at the blocked frame's box, and at
    /// (50, 150) after the page moves the blocked frame there.
    private static let hitTests = """
    const b = document.getElementById("b");
    const before = document.elementFromPoint(250, 50);
    b.style.left = "10px"; b.style.top = "110px";
    const moved = document.elementFromPoint(50, 150);
    b.style.left = "200px"; b.style.top = "10px";
    return [before ? before.id || before.tagName : null, moved ? moved.id || moved.tagName : null];
    """

    private static let focusBlocked = """
    document.getElementById("b").focus();
    const e = document.activeElement;
    return e ? e.id || e.tagName : null;
    """

    private func guarded<T>(_ page: FramePage, _ gate: BrowserReplFrameGate, _ body: () async throws -> T) async throws -> T {
        let webView = page.webView
        return try await gate.guardingInput(in: webView, frames: { await BrowserReplFrame.readTree(of: webView) }, checkFocusAfter: true, body)
    }

    @Test("While input is in flight a blocked frame is not hit, also after the page moves it under the point")
    func blockedFrameIsNotHitTested() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let unguarded = try await page.run(Self.hitTests, in: page.main) as? [String]
        #expect(unguarded == ["b", "b"], "the test page does not hit-test its frame: \(String(describing: unguarded))")
        let hits = try await guarded(page, gate) { try await page.run(Self.hitTests, in: page.main) as? [String] }
        #expect(hits?.contains("b") == false, "the blocked frame was hit while input was in flight: \(String(describing: hits))")
        let after = try await page.run(Self.hitTests, in: page.main) as? [String]
        #expect(after == ["b", "b"], "the guard stayed on after the input: \(String(describing: after))")
        let inert = try await page.run(#"return document.getElementById("b").hasAttribute("inert")"#, in: page.main) as? Bool
        #expect(inert == false)
    }

    @Test("While input is in flight the page cannot move the focus into a blocked frame")
    func blockedFrameIsNotFocusable() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let focused = try await guarded(page, gate) { try await page.run(Self.focusBlocked, in: page.main) as? String }
        #expect(focused != "b", "the page focused the blocked frame while input was in flight")
    }

    @Test("A page that takes the guard off during the input fails it with blocked")
    func removedGuardFailsTheInput() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let error = await BrowserReplFrameGateTests.error {
            try await guarded(page, gate) {
                try await page.run(#"document.getElementById("b").removeAttribute("inert"); return true"#, in: page.main)
            }
        }
        #expect(error?.code == "blocked", "the input went on after the page took the guard off: \(String(describing: error))")
    }

    @Test("A frame element the page made inert itself stays inert")
    func pageInertStays() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        _ = try await page.run(#"document.getElementById("b").inert = true; return true"#, in: page.main)
        _ = try await guarded(page, gate) { true }
        let inert = try await page.run(#"return document.getElementById("b").hasAttribute("inert")"#, in: page.main) as? Bool
        #expect(inert == true)
    }

    @Test("A blocked frame in a shadow tree is guarded too")
    func shadowTreeBlockedFrameIsGuarded() async throws {
        let page = try await FramePage.load(
            html: """
            <div id=host></div>
            <script>
              document.getElementById("host").attachShadow({ mode: "open" }).innerHTML =
                '<iframe id=b src="cmux-test://blocked.test/x" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>';
            </script>
            <iframe id=a src="cmux-test://allowed.test/child" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
            """,
            loaded: { frames in frames.count >= 3 && frames.allSatisfy { !$0.url.isEmpty } }
        )
        let gate = BrowserReplFrameGateTests.gate()
        let probe = """
        const b = document.getElementById("host").shadowRoot.getElementById("b");
        const hit = document.elementFromPoint(250, 50);
        return [b.hasAttribute("inert"), hit === document.getElementById("host")];
        """
        let during = try await guarded(page, gate) { try await page.run(probe, in: page.main) as? [Bool] }
        #expect(during?.first == true, "the blocked frame in a shadow tree was not guarded")
        #expect(during?.last == false, "the blocked frame in a shadow tree was hit")
    }

    @Test("A page that reorders its frames while the guard is set up does not leave the blocked frame unguarded")
    func reorderedFramesKeepTheBlockedFrameGuarded() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let webView = page.webView
        // a is window.frames[0] and the blocked b [1]; moving a after b
        // makes b [0] once b reported its position.
        gate.inputPositionsRead = {
            _ = try? await webView.callAsyncJavaScript(
                #"document.body.appendChild(document.getElementById("a")); return true"#,
                arguments: [:], in: nil, contentWorld: .page
            )
        }
        var blockedInert: Bool?
        let error = await BrowserReplFrameGateTests.error {
            try await guarded(page, gate) {
                blockedInert = try await page.run(#"return document.getElementById("b").hasAttribute("inert")"#, in: page.main) as? Bool
                return true
            }
        }
        #expect(error != nil || blockedInert == true, "the input ran with the blocked frame unguarded after the page reordered its frames")
        if let error { #expect(error.code == "stale", "\(error)") }
        // Once the page holds still, the next input guards the blocked frame.
        gate.inputPositionsRead = nil
        let inert = try await guarded(page, gate) {
            try await page.run(#"return document.getElementById("b").hasAttribute("inert")"#, in: page.main) as? Bool
        }
        #expect(inert == true, "the blocked frame was not guarded after the reorder")
    }
}
