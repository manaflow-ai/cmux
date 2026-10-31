import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
@testable import CmuxNextPages
import CmuxNextTestSupport
import Testing
import WebKit

/// The code editor page (Monaco) gets the VS Code chords while it has the keyboard
/// (`codeEditorFocused`), resolved as the key dispatcher decides a key-down. Lawrence 2026-10-19:
/// "supports all common vscode shortcuts", "cmd shift l doesnt work in monaco editor". Live on
/// cmux-lawrence-2 (fleet build of e10a2d6a318), Cmd-D split the pane and Cmd-Opt-Down moved the
/// focus inside the editor: Ghostty's own default keybinds (`super+d=new_split:right`,
/// `super+alt+down=goto_split:down`) won after cmux's defaults stepped aside; Cmd-[ / Cmd-] (outdent,
/// indent) were consumed as browser-only Back / Forward.
@MainActor @Suite(.closesItsWindows) struct CodeEditorKeysTests {
    static let bound: [ActionID] = [
        "splitRight", "splitDown", "openBrowser", "focusUp", "focusDown", "focusLocation", "browserBack", "browserForward",
        "focusHistoryBack", "focusHistoryForward", "toggleChecklistItemComplete", "toggleSplitZoom", "quit",
        "fileEditorZoomReset", "splitBrowserRight",
    ]

    /// The registry the router reads; the router holds it `unowned`, so the suite keeps it.
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        for id in bound { registry.bind(id, invoke: { _ in }) }
        // Ghostty's macOS defaults for these keys, as the App loads them (`.ghosttyFallback`).
        let fallback: [(Shortcut, ActionID)] = [
            (Shortcut("d", modifiers: [.command]), "splitRight"),
            (Shortcut("d", modifiers: [.command, .shift]), "splitDown"),
            (Shortcut(Shortcut.upArrowKey, modifiers: [.command, .option]), "focusUp"),
            (Shortcut(Shortcut.downArrowKey, modifiers: [.command, .option]), "focusDown"),
        ]
        KeyBindingLoader(registry).loadGhostty(fallback.map { KeyBinding(keys: [$0.0], command: $0.1, source: .ghosttyFallback) })
        return registry
    }()

    static func router() -> KeyRouter { KeyRouter(registry: registry) }

    static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    static var pageFocus: FocusState {
        var focus = FocusState()
        focus.resolved = .page(pane: "pane_editor", tab: "tab_editor")
        return focus
    }

    static func decision(_ event: NSEvent, editor: Bool, sequence: Bool = false) -> String {
        let facts = KeyFacts(pageID: editor ? KeyRouter.codeEditorPageID : "cmux.settings", pageKeySequencePending: sequence)
        return String(describing: router().decide(event, focus: pageFocus, keyWindow: .content, facts: facts))
    }

    nonisolated static let editorChords: [(String, String, NSEvent.ModifierFlags, UInt16)] = [
        ("Cmd-Shift-L select all occurrences", "l", [.command, .shift], 37),
        ("Cmd-D add next match", "d", [.command], 2),
        ("Cmd-Opt-Up add cursor above", Shortcut.upArrowKey, [.command, .option, .numericPad, .function], 126),
        ("Cmd-Opt-Down add cursor below", Shortcut.downArrowKey, [.command, .option, .numericPad, .function], 125),
        ("Cmd-[ outdent", "[", [.command], 33),
        ("Cmd-] indent", "]", [.command], 30),
        ("Cmd-L expand line selection", "l", [.command], 37),
        ("Opt-Cmd-L toggle find in selection", "l", [.command, .option], 37),
        ("Cmd-Return insert line below", "\r", [.command], 36),
        ("Shift-Cmd-Return insert line above", "\r", [.command, .shift], 36),
    ]

    @Test(arguments: editorChords)
    func theEditorGetsItsVSCodeChord(_ chord: (String, String, NSEvent.ModifierFlags, UInt16)) throws {
        let event = try Self.key(chord.1, chord.2, keyCode: chord.3)
        #expect(Self.decision(event, editor: true) == "deliver", "\(chord.0) did not reach the editor")
    }

    /// Outside the editor the same keys keep their app actions (the split, the focus moves).
    @Test func outsideTheEditorTheAppKeepsItsKeys() throws {
        #expect(Self.decision(try Self.key("d", [.command], keyCode: 2), editor: false).contains("splitRight"))
        #expect(Self.decision(try Self.key(Shortcut.downArrowKey, [.command, .option, .numericPad, .function], keyCode: 125),
                              editor: false).contains("focusDown"))
    }

    /// Cmd-K Cmd-0 (fold all): while Monaco waits for the second key, the app's Cmd-0 (zoom reset in
    /// the editor) steps aside; a system chord such as Quit still runs.
    @Test func aPendingKeySequenceTakesTheNextKey() throws {
        let zero = try Self.key("0", [.command], keyCode: 29)
        #expect(Self.decision(zero, editor: true).contains("fileEditorZoomReset"))
        #expect(Self.decision(zero, editor: true, sequence: true) == "deliver")
        let quit = try Self.key("q", [.command], keyCode: 12)
        #expect(Self.decision(quit, editor: true, sequence: true).contains("quit"))
    }

    /// A page web view with `id`, not loaded.
    static func page(_ id: String) -> PageWebView {
        let configuration = WKWebViewConfiguration()
        return PageWebView(descriptor: PageDescriptor(id: id, resource: "keys", namespaces: []), configuration: configuration,
                           inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: nil,
                           options: .standard, surface: nil, dynamicResources: nil, pooled: false, load: false, chromium: nil)
    }

    /// Shift-Cmd-L opened a browser tab while the editor had the keyboard: the focus model still named
    /// the Markdown tab of another pane, so the keys took that page's context. The page whose web view
    /// is the first responder gets the keys; the model's page counts only when the editor does not.
    @Test func theEditorHoldingTheKeysWinsOverTheModelsPage() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let markdown = Self.page("cmux.markdown"), editor = Self.page(KeyRouter.codeEditorPageID)
        markdown.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        editor.frame = NSRect(x: 200, y: 0, width: 200, height: 300)
        window.contentView?.addSubview(markdown)
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor.webKitView))
        #expect(KeyRouter.keyPage(modelPage: markdown, in: window) === editor)
        #expect(window.makeFirstResponder(markdown.webKitView))
        #expect(KeyRouter.keyPage(modelPage: markdown, in: window) === markdown)
        #expect(window.makeFirstResponder(nil))
        #expect(KeyRouter.keyPage(modelPage: nil, in: window) == nil)
    }

    /// A Ghostty keybind the user wrote (`.ghostty`) still wins in the editor, as everywhere.
    @Test func theUsersOwnGhosttyKeybindStillWins() {
        let accepts = KeyRouter.acceptsEntry(ghostty: true, codeEditor: true)
        let shortcut = Shortcut("d", modifiers: [.command])
        #expect(!accepts(KeyBinding(keys: [shortcut], command: "splitRight", source: .ghosttyFallback)))
        #expect(accepts(KeyBinding(keys: [shortcut], command: "splitRight", source: .ghostty)))
        #expect(KeyRouter.acceptsEntry(ghostty: true, codeEditor: false)(KeyBinding(keys: [shortcut], command: "splitRight", source: .ghosttyFallback)))
    }
}
