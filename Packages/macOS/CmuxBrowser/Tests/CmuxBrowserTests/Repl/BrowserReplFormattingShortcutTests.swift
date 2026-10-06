import Testing
import WebKit

@testable import CmuxBrowser

/// Meta+B, Meta+I and Meta+U run `document.execCommand` in the main
/// frame's document after WebKit reports that no page handled the key. The
/// page can navigate the main frame while that report is on its way, so the
/// command runs through the frame gate, which judges the document it runs
/// in, in the same script turn: a page the session's authority refuses is
/// never formatted.
@MainActor
@Suite("Formatting shortcuts", .serialized)
struct BrowserReplFormattingShortcutTests {
    private static let editablePage = """
        <div id=e contenteditable>format me</div>
        <script>
        const e = document.getElementById('e');
        e.focus();
        getSelection().selectAllChildren(e);
        </script>
        """

    @Test("Bold formats the focused editable of a page the authority allows")
    func boldFormatsAnAllowedPage() async throws {
        let page = try await FramePage.load(html: Self.editablePage)
        let gate = BrowserReplFrameGateTests.gate()
        let ran = try await gate.runFormattingShortcut(.bold, in: page.webView)
        #expect(ran)
        let html = try await page.run("return document.getElementById('e').innerHTML", in: page.main) as? String
        #expect(html?.contains("<b>") == true, "the allowed page was not formatted: \(html ?? "nil")")
    }

    /// r22: the main frame navigates to a page the policy blocks between
    /// the key's delivery and the command. The command is refused there and
    /// formats nothing.
    @Test("A main frame that navigated to a blocked page meanwhile is not formatted")
    func aMainFrameThatNavigatedToABlockedPageIsNotFormatted() async throws {
        let page = try await FramePage.load(html: Self.editablePage)
        let gate = BrowserReplFrameGateTests.gate()
        let webView = page.webView
        let error = await BrowserReplFrameGateTests.error {
            try await gate.runFormattingShortcut(.bold, in: webView, beforeDelivery: {
                webView.load(URLRequest(url: URL(string: "cmux-test://blocked.test/")!))
                _ = try await FramePage.settle(webView) { frames in
                    frames.first.flatMap { URL(string: $0.url)?.host } == "blocked.test"
                }
                _ = try await webView.callAsyncJavaScript(
                    "const e = document.getElementById('e'); e.focus(); getSelection().selectAllChildren(e); return document.readyState",
                    arguments: [:], in: nil, contentWorld: .page
                )
            })
        }
        #expect(error?.code == "blocked", "the command ran on a blocked page: \(String(describing: error))")
        let html = try await webView.callAsyncJavaScript("return document.getElementById('e').innerHTML", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(html == "format me", "the blocked page was formatted: \(html ?? "nil")")
    }
}
