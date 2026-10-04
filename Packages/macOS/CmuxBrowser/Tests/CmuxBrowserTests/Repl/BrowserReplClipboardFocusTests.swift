import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// Meta+C, Meta+X and Meta+V run WebKit's Copy, Cut and Paste on the frame
/// that holds the focus when the command runs, after the key reached the
/// page. A page's keydown handler can move the focus into a frame the
/// domain policy blocks between the check before the key and the command,
/// so the tab's clipboard would take that frame's selection (or paste into
/// it). The gate checks the focus again around the command.
@MainActor
@Suite("Clipboard command focus", .serialized)
struct BrowserReplClipboardFocusTests {
    private static let focusAllowedField = "document.getElementById('f').focus(); return document.activeElement.id"
    private static let focusBlockedFrame = "document.getElementById('b').focus(); return document.activeElement.id"

    @Test("A command whose focus moved into a blocked frame after the key does not run")
    func focusMovedBeforeTheCommandRefuses() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let allowed = try #require(page.frame(path: "/child"))
        _ = try await page.run(Self.focusAllowedField, in: allowed)
        #expect(await BrowserReplFrameGateTests.error { try await gate.checkFocus(in: page.webView, frames: page.frames) } == nil)
        // The key's handler moves the focus into the blocked frame.
        _ = try await page.run(Self.focusBlockedFrame, in: page.main)
        var ran = false
        let webView = page.webView
        let error = await BrowserReplFrameGateTests.error {
            try await gate.guardingFocus(in: webView, frames: { await BrowserReplFrame.readTree(of: webView) }) {
                ran = true
                return "copied"
            }
        }
        #expect(error?.code == "blocked", "the command ran with the focus in a blocked frame: \(String(describing: error))")
        #expect(!ran)
    }

    @Test("A command during which the focus moved into a blocked frame gives nothing back")
    func focusMovedDuringTheCommandRefuses() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let allowed = try #require(page.frame(path: "/child"))
        _ = try await page.run(Self.focusAllowedField, in: allowed)
        let webView = page.webView
        let main = page.main
        let error = await BrowserReplFrameGateTests.error {
            try await gate.guardingFocus(in: webView, frames: { await BrowserReplFrame.readTree(of: webView) }) {
                _ = try await webView.callAsyncJavaScript(Self.focusBlockedFrame, arguments: [:], in: main.info, contentWorld: .page)
                return "copied"
            }
        }
        #expect(error?.code == "blocked", "the command's result was taken with the focus in a blocked frame: \(String(describing: error))")
    }

    @Test("A command with the focus in an allowed frame runs and gives its result")
    func allowedFocusRuns() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let allowed = try #require(page.frame(path: "/child"))
        _ = try await page.run(Self.focusAllowedField, in: allowed)
        let webView = page.webView
        let value = try await gate.guardingFocus(in: webView, frames: { await BrowserReplFrame.readTree(of: webView) }) { "copied" }
        #expect(value == "copied")
    }

    @Test("A blocked frame focused through its element is found when a shadow-tree frame comes first")
    func ownerFocusWithAShadowFrameFirst() async throws {
        let page = try await FramePage.load(
            html: """
            <div id=host></div>
            <script>
              document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<iframe src="cmux-test://allowed.test/shadow"></iframe>';
            </script>
            <iframe id=a src="cmux-test://allowed.test/child"></iframe>
            <iframe id=b src="cmux-test://blocked.test/x"></iframe>
            """,
            loaded: { frames in frames.count >= 4 && frames.allSatisfy { !$0.url.isEmpty } }
        )
        let gate = BrowserReplFrameGateTests.gate()
        _ = try await page.run(Self.focusBlockedFrame, in: page.main)
        let error = await BrowserReplFrameGateTests.error { try await gate.checkFocus(in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "keys could reach the blocked frame its parent focused: \(String(describing: error))")
    }
}
