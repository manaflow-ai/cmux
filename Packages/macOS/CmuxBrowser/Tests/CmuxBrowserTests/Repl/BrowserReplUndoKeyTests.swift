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
@Suite(
    "Browser REPL undo and redo keys",
    .serialized,
    .enabled(if: BrowserReplKeyResendTests.webKitReportsKeyOutcome, Comment(rawValue: BrowserReplKeyResendTests.needsKeyOutcome))
)
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
    private func load(cancellingMetaKeys: Bool = false, blockedFrame: Bool = true, childPage: String? = nil) async throws -> Setup {
        var html = Self.page + (cancellingMetaKeys ? "<script>addEventListener('keydown', e => { if (e.metaKey) e.preventDefault(); });</script>" : "")
        if !blockedFrame { html = html.replacingOccurrences(of: "blocked.test", with: "allowed.test") }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FramePageSchemeHandler(mainPage: html, childPage: childPage), forURLScheme: "cmux-test")
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
        // A tab that shows a blocked frame refuses Undo and Redo outright
        // (replKeysAfterTheMainDocumentFocusesABlockedFrameFromScriptDoNotReachIt).
        let setup = try await load(blockedFrame: false)
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

    /// Two edits in two editables (a focus change between them, so WebKit
    /// keeps them as two undo steps), then the focus back in the first.
    /// The page logs each history input it gets.
    private func loadWithTwoEdits() async throws -> Setup {
        let setup = try await load(blockedFrame: false)
        _ = try await setup.page.run("""
            const e2 = document.createElement('div'); e2.id = 'e2'; e2.contentEditable = 'true'; e2.textContent = 'second'; document.body.prepend(e2);
            window.history_ = []; addEventListener('input', (ev) => { if (ev.inputType.startsWith('history')) window.history_.push(ev.inputType); }, true);
            const e = document.getElementById('e'); e.focus(); getSelection().selectAllChildren(e); document.execCommand('insertText', false, 'one');
            return true
            """, in: setup.page.main)
        _ = try await setup.page.run("e2.focus(); getSelection().selectAllChildren(e2); document.execCommand('insertText', false, 'two'); return true", in: setup.page.main)
        try await waitForEditableFocus(setup.webView)
        #expect(try await texts(setup) == ["one", "two"])
        return setup
    }

    private func texts(_ setup: Setup) async throws -> [String] {
        try await setup.page.run("return [document.getElementById('e').textContent, document.getElementById('e2').textContent]", in: setup.page.main) as? [String] ?? []
    }

    private func historyInputs(_ setup: Setup) async throws -> [String] {
        try await setup.page.run("return window.history_", in: setup.page.main) as? [String] ?? []
    }

    /// One agent Meta+Z undoes one step and one Shift+Meta+Z redoes one
    /// step. Seen on the real app (gate on da48df7b6ee6): one Meta+Z after
    /// an edit undid two steps (two `historyUndo` inputs).
    @Test func oneReplUndoKeyUndoesOneStepAndOneRedoKeyRedoesOneStep() async throws {
        let setup = try await loadWithTwoEdits()
        defer { setup.window.close() }
        let gate = BrowserReplFrameGateTests.gate()
        #expect(try await replUndoKey(redo: false, in: setup.webView, gate: gate) == nil)
        #expect(try await texts(setup) == ["one", "second"], "one Meta+Z did not undo exactly the last edit")
        #expect(try await historyInputs(setup) == ["historyUndo"], "one Meta+Z ran more than one undo")
        #expect(try await replUndoKey(redo: true, in: setup.webView, gate: gate) == nil)
        #expect(try await texts(setup) == ["one", "two"], "one Shift+Meta+Z did not redo exactly one edit")
        #expect(try await historyInputs(setup) == ["historyUndo", "historyRedo"], "one Shift+Meta+Z ran more than one redo")
    }

    /// The same through `cmux browser press`: Meta down, z (Z) pressed,
    /// Meta up, one socket call each.
    @Test func oneCmuxBrowserPressUndoKeyUndoesOneStepAndOneRedoKeyRedoesOneStep() async throws {
        let setup = try await loadWithTwoEdits()
        defer { setup.window.close() }
        func press(_ keys: [String]) async throws {
            let events = try keys.map { try #require(BrowserKeyboardEvent(rawKey: $0)) }
            try await BrowserReplKeyResendTests.withAppDroppingResends {
                for event in events.dropLast() { #expect(await setup.webView.replayBrowserKeyboardEvent(event, action: .keyDown) == .delivered) }
                #expect(await setup.webView.replayBrowserKeyboardEvent(events[events.count - 1], action: .press) == .delivered)
                for event in events.dropLast().reversed() { #expect(await setup.webView.replayBrowserKeyboardEvent(event, action: .keyUp) == .delivered) }
                await setup.webView.waitForQueuedAutomationKeyEvents()
                _ = try await setup.webView.evaluateJavaScript("0")
            }
        }
        try await press(["Meta", "z"])
        #expect(try await texts(setup) == ["one", "second"], "one Meta+Z did not undo exactly the last edit")
        #expect(try await historyInputs(setup) == ["historyUndo"], "one Meta+Z ran more than one undo")
        try await press(["Meta", "Shift", "z"])
        #expect(try await texts(setup) == ["one", "two"], "one Shift+Meta+Z did not redo exactly one edit")
        #expect(try await historyInputs(setup) == ["historyUndo", "historyRedo"], "one Shift+Meta+Z ran more than one redo")
    }

    /// Typed text and a Backspace right after it are one undo step in
    /// WebKit (its open typing command takes the deletion), so one Meta+Z
    /// takes both back: the same as one Command-Z of a person (the web
    /// view's own undo stack, one `undo()`), with one `historyUndo` input
    /// (a `beforeinput` and an `input` both carry that type).
    @Test func oneReplUndoKeyAfterTypingAndBackspaceUndoesWhatOnePersonsUndoDoes() async throws {
        var results: [[String]] = []
        for viaRepl in [false, true] {
            let setup = try await load(blockedFrame: false)
            defer { setup.window.close() }
            _ = try await setup.page.run("""
                const e = document.getElementById('e'); e.focus(); getSelection().selectAllChildren(e); getSelection().collapseToEnd();
                window.history_ = []; addEventListener('input', (ev) => { if (ev.inputType.startsWith('history')) window.history_.push(ev.inputType); }, true);
                return true
                """, in: setup.page.main)
            try await waitForEditableFocus(setup.webView)
            try await BrowserReplKeyResendTests.withAppDroppingResends {
                for key in ["a", "b", "c", "Backspace"] {
                    let stroke = try #require(try BrowserReplKeyStroke.resolve(key: key, code: key == "Backspace" ? "Backspace" : "Key\(key.uppercased())", text: key == "Backspace" ? nil : key, modifiers: []))
                    _ = setup.webView.replayBrowserReplKeyStroke(stroke, keyDown: true, heldBy: "session")
                    _ = setup.webView.replayBrowserReplKeyStroke(stroke, keyDown: false, heldBy: "session")
                    await setup.webView.waitForQueuedAutomationKeyEvents()
                }
            }
            // WebKit hands each key to the input method first: wait until
            // the page has all four.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline, try await text(setup) != "edit meab" {
                await setup.webView.waitForQueuedAutomationKeyEvents()
            }
            #expect(try await text(setup) == "edit meab")
            if viaRepl {
                #expect(try await replUndoKey(redo: false, in: setup.webView, gate: BrowserReplFrameGateTests.gate()) == nil)
            } else {
                (setup.webView as? CmuxUndoableWebView)?.performWebContentUndoRedo(redo: false)
            }
            _ = try await setup.webView.evaluateJavaScript("0")
            results.append([try await text(setup) ?? ""] + (try await historyInputs(setup)))
        }
        #expect(results[1] == results[0], "one Meta+Z (\(results[1])) did not do what one person's undo does (\(results[0]))")
        #expect(results[1] == ["edit me", "historyUndo"])
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

    /// A blocked frame's page: a field, logging the key and input events
    /// that reach its document.
    private static let loggingBlockedPage = "<input id=f value='blocked text'><script>window.log = []; for (const t of ['keydown', 'keypress', 'keyup', 'beforeinput', 'input']) addEventListener(t, (e) => { window.log.push(t + ':' + (e.key || e.inputType)); }, true);</script>"

    /// Sends one key as the REPL driver does: inside the frame gate's input
    /// guard (the blocked frame's element inert), the focus check, the key,
    /// then for an Edit menu shortcut no page handled its command through
    /// the gate.
    private func replKey(_ key: String, modifiers: [String], in webView: WKWebView, gate: BrowserReplFrameGate) async -> BrowserReplDriverError? {
        await BrowserReplFrameGateTests.error {
            let stroke = try #require(try BrowserReplKeyStroke.resolve(key: key, code: "Key\(key.uppercased())", text: modifiers.isEmpty ? key : nil, modifiers: modifiers))
            let frames: @MainActor () async -> [BrowserReplFrame] = { await BrowserReplFrame.readTree(of: webView) }
            try await BrowserReplKeyResendTests.withAppDroppingResends {
                try await gate.guardingInput(in: webView, frames: frames, checkFocusAfter: true) {
                    try await gate.checkFocus(in: webView, frames: await frames())
                    let delivery = try await webView.deliverAutomationKeyDown(watchingOutcome: stroke.editingCommand != nil) {
                        try gate.checkTab(in: webView)
                        return webView.replayBrowserReplKeyStroke(stroke, keyDown: true, heldBy: "session")
                    }
                    defer { _ = webView.replayBrowserReplKeyStroke(stroke, keyDown: false, heldBy: "session") }
                    if let command = stroke.editingCommand.flatMap(BrowserReplFrameGate.EditingShortcut.init(action:)),
                       let outcome = delivery.outcome, await outcome.wasUnhandled() {
                        try await gate.runEditingShortcut(command, in: webView, frames: frames)
                    }
                }
            }
            _ = try await webView.evaluateJavaScript("0")
            return nil
        }
    }

    /// The main document focuses a blocked frame's element from script
    /// (nothing clicked into the frame) after that frame made an edit of
    /// its own. In the app the gate's input guard makes the element inert
    /// and WebKit moves the focus out of it on its next rendering update,
    /// so the keys go to the main document; here the page blurs it when it
    /// turns inert, which a page may also do itself. The blocked frame must
    /// then get no key event, and the session's Meta+Z or Shift+Meta+Z
    /// must not undo or redo its edit through the tab's undo stack, which
    /// holds it: they are refused (`blocked`). A plain key runs.
    @Test func replKeysAfterTheMainDocumentFocusesABlockedFrameFromScriptDoNotReachIt() async throws {
        let setup = try await load(childPage: Self.loggingBlockedPage)
        defer { setup.window.close() }
        let blocked = try #require(setup.page.frame(host: "blocked.test"))
        _ = try await setup.page.run("const f = document.getElementById('f'); f.focus(); f.select(); document.execCommand('insertText', false, 'edited'); f.blur(); window.log = []; return true", in: blocked)
        _ = try await setup.page.run("const b = document.getElementById('b'); new MutationObserver(() => { if (b.inert) b.blur(); }).observe(b, { attributes: true }); b.focus(); return true", in: setup.page.main)
        let gate = BrowserReplFrameGateTests.gate()
        for (key, modifiers, expected) in [("z", ["Meta"], "blocked"), ("Z", ["Meta", "Shift"], "blocked"), ("x", [String](), "ran")] {
            let error = await replKey(key, modifiers: modifiers, in: setup.webView, gate: gate)
            let name = (modifiers + [key]).joined(separator: "+")
            #expect((error?.code ?? "ran") == expected, "\(name): \(String(describing: error))")
            let log = try await setup.page.run("return window.log.join(',')", in: blocked) as? String
            #expect(log == "", "\(name) reached the blocked frame: \(String(describing: log))")
            let value = try await setup.page.run("return document.getElementById('f').value", in: blocked) as? String
            #expect(value == "edited", "\(name) changed the blocked frame's field")
        }
        let keys = try await setup.page.run("return window.keys", in: setup.page.main) as? Int
        #expect(keys == 3, "the main document did not get the keys: \(String(describing: keys))")
    }
}
