import Testing
import WebKit

@testable import CmuxBrowser

/// Meta+A, Meta+Z and Shift+Meta+Z that no page handled run Select All,
/// Undo and Redo in the document that holds the keyboard focus. WebKit
/// reports that no page handled the key after an await, and the page can
/// navigate or move the focus meanwhile, so the command runs through the
/// frame gate, which judges the document it runs in, in the same script
/// turn: a document the session's authority refuses gets no command.
@MainActor
@Suite("Editing shortcuts", .serialized)
struct BrowserReplEditingShortcutTests {
    private static let editablePage = """
        <input id=f value="select me">
        <div id=e contenteditable>edit me</div>
        <script>document.getElementById('f').focus();</script>
        """

    private static func selection(_ webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript(
            "const f = document.getElementById('f'); return f.value.slice(f.selectionStart, f.selectionEnd);",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
    }

    @Test("Select All selects the focused field of a page the authority allows")
    func selectAllSelectsInAnAllowedPage() async throws {
        let page = try await FramePage.load(html: Self.editablePage)
        let gate = BrowserReplFrameGateTests.gate()
        let webView = page.webView
        try await gate.runEditingShortcut(.selectAll, in: webView, frames: { await BrowserReplFrame.readTree(of: webView) })
        #expect(try await Self.selection(webView) == "select me")
    }

    /// A web view with the undo manager a window gives it in the app:
    /// WebKit registers edits, and answers Undo and Redo, only through one.
    private final class UndoingWebView: WKWebView {
        private let manager = UndoManager()
        override var undoManager: UndoManager? { manager }
    }

    @Test("Undo and Redo reverse and repeat the last edit of a page the authority allows")
    func undoAndRedoRunInAnAllowedPage() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FramePageSchemeHandler(mainPage: Self.editablePage), forURLScheme: "cmux-test")
        let webView = UndoingWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.load(URLRequest(url: URL(string: "cmux-test://allowed.test/")!))
        let page = FramePage(webView: webView, frames: try await FramePage.settle(webView) { $0.count == 1 && !$0[0].url.isEmpty })
        let gate = BrowserReplFrameGateTests.gate()
        let frames: @MainActor () async -> [BrowserReplFrame] = { await BrowserReplFrame.readTree(of: webView) }
        _ = try await page.run(
            "const e = document.getElementById('e'); e.focus(); getSelection().selectAllChildren(e); document.execCommand('insertText', false, 'typed'); return true",
            in: page.main
        )
        let text = { try await page.run("return document.getElementById('e').textContent", in: page.main) as? String }
        #expect(try await text() == "typed")
        try await gate.runEditingShortcut(.undo, in: webView, frames: frames)
        #expect(try await text() == "edit me")
        try await gate.runEditingShortcut(.redo, in: webView, frames: frames)
        #expect(try await text() == "typed")
    }

    /// r26: the main frame navigates to a page the policy blocks between the
    /// key's delivery and the command. The command is refused there.
    @Test("A main frame that navigated to a blocked page meanwhile gets no Select All")
    func aMainFrameThatNavigatedToABlockedPageGetsNoSelectAll() async throws {
        let page = try await FramePage.load(html: Self.editablePage)
        let gate = BrowserReplFrameGateTests.gate()
        let webView = page.webView
        let error = await BrowserReplFrameGateTests.error {
            try await gate.runEditingShortcut(.selectAll, in: webView, frames: { await BrowserReplFrame.readTree(of: webView) }, beforeDelivery: {
                webView.load(URLRequest(url: URL(string: "cmux-test://blocked.test/")!))
                _ = try await FramePage.settle(webView) { frames in
                    frames.first.flatMap { URL(string: $0.url)?.host } == "blocked.test"
                }
                _ = try await webView.callAsyncJavaScript(
                    "const f = document.getElementById('f'); f.focus(); f.setSelectionRange(0, 0); return document.readyState",
                    arguments: [:], in: nil, contentWorld: .page
                )
            })
        }
        #expect(error?.code == "blocked", "the command ran on a blocked page: \(String(describing: error))")
        #expect(try await Self.selection(webView) == "", "the blocked page's field was selected")
    }

    @Test("Select All, Undo and Redo with the focus in a blocked frame are refused")
    func shortcutsWithTheFocusInABlockedFrameAreRefused() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        _ = try await page.run("document.getElementById('b').focus(); return true", in: page.main)
        _ = try await page.run("const f = document.getElementById('f'); f.value = 'blocked text'; f.focus(); f.setSelectionRange(0, 0); return true", in: blocked)
        let webView = page.webView
        for shortcut in [BrowserReplFrameGate.EditingShortcut.selectAll, .undo, .redo] {
            let error = await BrowserReplFrameGateTests.error {
                try await gate.runEditingShortcut(shortcut, in: webView, frames: { await BrowserReplFrame.readTree(of: webView) })
            }
            #expect(error?.code == "blocked", "\(shortcut) ran with the focus in a blocked frame: \(String(describing: error))")
        }
        let selected = try await page.run("const f = document.getElementById('f'); return f.selectionEnd - f.selectionStart", in: blocked) as? Int
        #expect(selected == 0, "the blocked frame's field was selected")
    }
}
