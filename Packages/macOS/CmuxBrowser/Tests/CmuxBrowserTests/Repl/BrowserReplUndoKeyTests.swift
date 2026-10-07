import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// A REPL session's Meta+Z and Shift+Meta+Z go the way of its other Edit
/// menu shortcuts: the page gets the keydown first and can cancel it, and
/// only a key no page handled runs Undo or Redo, through the frame gate,
/// which judges the focused frame and its document in the command's own
/// turn. The app's web views undo a Command-Z chord themselves in
/// `keyDown` (CmuxUndoableWebView); before this, an agent's chord took that
/// path, so the page never saw the key and the undo reached the tab's last
/// edit wherever the focus was, a blocked frame included.
@MainActor
@Suite("Browser REPL undo and redo keys", .serialized)
struct BrowserReplUndoKeyTests {
    /// A web view that, like the app's, undoes a Command-Z chord itself.
    final class UndoChordWebView: CmuxUndoableWebView {
        override func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            return event.charactersIgnoringModifiers?.lowercased() == "z" && (flags == [.command] || flags == [.command, .shift])
        }
    }

    private static let page = """
        <div id=e contenteditable>edit me</div>
        <iframe id=b src="cmux-test://blocked.test/x" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>
        <script>window.keys = 0; addEventListener('keydown', () => { window.keys++; });</script>
        """

    private struct Setup {
        let window: NSWindow
        let page: FramePage
        var webView: WKWebView { page.webView }
    }

    /// The page in an app-like web view, in a window, as its first responder.
    private func load(cancellingMetaKeys: Bool = false) async throws -> Setup {
        let html = Self.page + (cancellingMetaKeys ? "<script>addEventListener('keydown', e => { if (e.metaKey) e.preventDefault(); });</script>" : "")
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FramePageSchemeHandler(mainPage: html), forURLScheme: "cmux-test")
        let webView = UndoChordWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        #expect(window.makeFirstResponder(webView))
        webView.load(URLRequest(url: URL(string: "cmux-test://allowed.test/")!))
        let frames = try await FramePage.settle(webView) { $0.count >= 2 && $0.allSatisfy { !$0.url.isEmpty } }
        return Setup(window: window, page: FramePage(webView: webView, frames: frames))
    }

    /// Waits until WebKit reports the editable focus to the UI process.
    private func waitForEditableFocus(_ webView: WKWebView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline, webView.inputContext == nil {
            _ = try await webView.evaluateJavaScript("0")
        }
        try #require(webView.inputContext != nil, "the focused editable never gave the web view an input context")
    }

    /// Sends Meta+Z (Shift+Meta+Z for `redo`) as the REPL driver does: the
    /// earlier keys out of WebKit's queue, the key through WebKit, its
    /// outcome, then, for a key no page handled, the command through the
    /// frame gate.
    private func replUndoKey(redo: Bool, in webView: WKWebView, gate: BrowserReplFrameGate) async throws -> BrowserReplDriverError? {
        let stroke = try #require(try BrowserReplKeyStroke.resolve(key: redo ? "Z" : "z", code: "KeyZ", text: nil, modifiers: redo ? ["Meta", "Shift"] : ["Meta"]))
        #expect(stroke.editingCommand == (redo ? "redo:" : "undo:"))
        var failure: BrowserReplDriverError?
        try await BrowserReplKeyResendTests.withAppDroppingResends {
            let delivery = await webView.deliverAutomationKeyDown(watchingOutcome: true) {
                webView.replayBrowserReplKeyStroke(stroke, keyDown: true, heldBy: "session")
            }
            #expect(delivery.result == .delivered)
            let outcome = try #require(delivery.outcome)
            if await outcome.wasUnhandled() {
                failure = await BrowserReplFrameGateTests.error {
                    try await gate.runEditingShortcut(redo ? .redo : .undo, in: webView, frames: { await BrowserReplFrame.readTree(of: webView) })
                }
            }
            _ = webView.replayBrowserReplKeyStroke(stroke, keyDown: false, heldBy: "session")
        }
        return failure
    }

    private func typeInEditable(_ setup: Setup) async throws {
        _ = try await setup.page.run(
            "const e = document.getElementById('e'); e.focus(); getSelection().selectAllChildren(e); document.execCommand('insertText', false, 'typed'); return true",
            in: setup.page.main
        )
        try await waitForEditableFocus(setup.webView)
    }

    private func text(_ setup: Setup) async throws -> String? {
        try await setup.page.run("return document.getElementById('e').textContent", in: setup.page.main) as? String
    }

    @Test func replUndoAndRedoInAnAllowedDocumentReachThePageThenRunThroughTheGate() async throws {
        let setup = try await load()
        defer { setup.window.close() }
        try await typeInEditable(setup)
        #expect(try await text(setup) == "typed")
        let gate = BrowserReplFrameGateTests.gate()
        #expect(try await replUndoKey(redo: false, in: setup.webView, gate: gate) == nil)
        #expect(try await text(setup) == "edit me", "Meta+Z did not undo the allowed document's edit")
        #expect(try await replUndoKey(redo: true, in: setup.webView, gate: gate) == nil)
        #expect(try await text(setup) == "typed", "Shift+Meta+Z did not redo the allowed document's edit")
        let keys = try await setup.page.run("return window.keys", in: setup.page.main) as? Int
        #expect(keys == 2, "the page did not get the keydown of each agent undo or redo chord: \(String(describing: keys))")
    }

    @Test func aReplUndoThePageCancelledRunsNothing() async throws {
        let setup = try await load(cancellingMetaKeys: true)
        defer { setup.window.close() }
        try await typeInEditable(setup)
        #expect(try await replUndoKey(redo: false, in: setup.webView, gate: BrowserReplFrameGateTests.gate()) == nil)
        #expect(try await text(setup) == "typed", "an undo ran for a chord the page cancelled")
    }

    @Test func aReplUndoWithTheFocusInABlockedFrameIsRefused() async throws {
        let setup = try await load()
        defer { setup.window.close() }
        let blocked = try #require(setup.page.frame(host: "blocked.test"))
        _ = try await setup.page.run("document.getElementById('b').focus(); return true", in: setup.page.main)
        _ = try await setup.page.run("const f = document.getElementById('f'); f.focus(); document.execCommand('insertText', false, 'blocked text'); return f.value", in: blocked)
        try await waitForEditableFocus(setup.webView)
        let error = try await replUndoKey(redo: false, in: setup.webView, gate: BrowserReplFrameGateTests.gate())
        #expect(error?.code == "blocked", "Meta+Z with the focus in a blocked frame was not refused: \(String(describing: error))")
        let value = try await setup.page.run("return document.getElementById('f').value", in: blocked) as? String
        #expect(value == "blocked text", "Meta+Z undid the blocked frame's edit")
    }
}
