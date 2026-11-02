import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextTestSupport
import Testing
import WebKit

/// Cmd-P (Go to Workspace) and Cmd-Shift-P (Command Palette) open the native Swift palettes from
/// every web view; no page handles them itself. Lawrence 2026-10-19: "All the web views should not
/// have a built-in Cmd-P or Cmd-Shift-P. They should all use the Swift version and call into the
/// Swift version somehow. It was on Agent Chat: Cmd-P and Cmd-Shift-P did something weird."
///
/// Before: in an agent chat Cmd-P ran the chat's own Search Files… (the page's file picker in the
/// composer), and in the floating Start Agent chat (an `NSPanel` with a web view, which the key
/// dispatcher never decided) Cmd-Shift-P reached the page, which kept the panel on top.
@MainActor @Suite(.closesItsWindows) struct WebViewNativePaletteKeysTests {
    /// The router holds the registry `unowned`; the suite keeps it.
    let registry: ActionRegistry
    let ran: Ran

    /// The actions that ran, in order.
    @MainActor final class Ran { var ids: [String] = [] }

    init() {
        let registry = ActionRegistry.standard()
        let ran = Ran()
        // The app binds a handler to every catalog action; a key runs only a bound one.
        for descriptor in ActionCatalog.all {
            let id = descriptor.id
            registry.bind(id) { ran.ids.append(id.rawValue) }
        }
        self.registry = registry
        self.ran = ran
    }

    func router() -> KeyRouter { KeyRouter(registry: registry) }

    static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    static func cmdP() throws -> NSEvent { try key("p", [.command], keyCode: 35) }
    static func cmdShiftP() throws -> NSEvent { try key("P", [.command, .shift], keyCode: 35) }

    /// Every kind of web view a main window shows, as the dispatcher sees its focus and facts.
    nonisolated static let webViewKinds: [String] = [
        "agent chat", "browser page", "address bar", "find bar", "DevTools", "markdown viewer", "code editor", "diff viewer",
        "settings page", "home",
    ]

    static func focusAndFacts(_ kind: String) -> (FocusState, KeyFacts) {
        var focus = FocusState()
        var facts = KeyFacts()
        switch kind {
        case "agent chat":
            focus.resolved = .agentPage(pane: "pane_a", tab: "tab_a")
            focus.context.agent = true
        case "browser page":
            focus.resolved = .browserPage(pane: "pane_a", tab: "tab_a")
            focus.context.browser = true
        case "address bar":
            focus.resolved = .addressBar(pane: "pane_a", tab: "tab_a")
            focus.context.browser = true
        case "find bar":
            focus.resolved = .findBar(pane: "pane_a", tab: "tab_a")
            focus.context.browser = true
        case "DevTools":
            focus.resolved = .devTools(pane: "pane_a", tab: "tab_a")
            focus.context.browser = true
        case "markdown viewer":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageID: KeyRouter.markdownPageID, pageEditableFocused: true)
        case "code editor":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageID: KeyRouter.codeEditorPageID, pageEditableFocused: true)
        case "diff viewer":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageID: KeyRouter.diffPageID)
        case "settings page":
            focus.resolved = .page(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageID: "cmux.settings", pageEditableFocused: true)
        default:
            focus.resolved = .conversation(pane: "pane_a", tab: "tab_a")
            facts = KeyFacts(pageEditableFocused: true, topPage: "home")
        }
        return (focus, facts)
    }

    /// In a main window the dispatcher runs the native palette before the page sees the key-down.
    @Test(arguments: webViewKinds)
    func cmdPAndCmdShiftPOpenTheNativePalettesInEveryWebView(_ kind: String) throws {
        let (focus, facts) = Self.focusAndFacts(kind)
        let router = router()
        let goTo = router.decide(try Self.cmdP(), focus: focus, keyWindow: .content, facts: facts)
        #expect(String(describing: goTo).contains("goToWorkspace"), "Cmd-P in the \(kind): \(goTo)")
        let palette = router.decide(try Self.cmdShiftP(), focus: focus, keyWindow: .content, facts: facts)
        #expect(String(describing: palette).contains("commandPalette"), "Cmd-Shift-P in the \(kind): \(palette)")
    }

    /// A window that is not a cmux main window (the floating Start Agent chat, a popup) with a web
    /// view as its first responder: the app opens the native palette and the key never reaches it.
    @Test func aWebViewInAPanelGetsTheNativePalettes() throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        defer { panel.closeAfterTest() }
        let webView = WKWebView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView?.addSubview(webView)
        #expect(panel.makeFirstResponder(webView))
        #expect(KeyRouter.webContentHasKeys(in: panel))
        let router = router()
        let cmdShiftP = try Self.cmdShiftP()
        #expect(router.routesNativePaletteKey(cmdShiftP, in: panel))
        #expect(router.decided.contains(cmdShiftP), "the window hook and the menu must not run it again")
        #expect(router.routesNativePaletteKey(try Self.cmdP(), in: panel))
        #expect(ran.ids == ["commandPalette", "goToWorkspace"])
        // Typing and other chords stay the page's.
        #expect(!router.routesNativePaletteKey(try Self.key("p", [], keyCode: 35), in: panel))
        #expect(!router.routesNativePaletteKey(try Self.key("j", [.command], keyCode: 38), in: panel))
        #expect(ran.ids == ["commandPalette", "goToWorkspace"])
    }

    /// A native text field in a panel (rename, a sheet) is not web content: this step leaves it to
    /// the panel and the menu, as before.
    @Test func aNativeFieldInAPanelIsNotWebContent() throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled],
                            backing: .buffered, defer: true)
        defer { panel.closeAfterTest() }
        let field = NSTextView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView?.addSubview(field)
        #expect(panel.makeFirstResponder(field))
        #expect(!KeyRouter.webContentHasKeys(in: panel))
        #expect(!router().routesNativePaletteKey(try Self.cmdShiftP(), in: panel))
        #expect(ran.ids.isEmpty)
    }

    /// The keys come from the binding table: a rebound palette moves with its action.
    @Test func aReboundPaletteKeyMovesWithItsAction() throws {
        registry.setShortcutOverride(Shortcut("e", modifiers: [.command, .shift]), for: "commandPalette")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled],
                            backing: .buffered, defer: true)
        defer { panel.closeAfterTest() }
        let webView = WKWebView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView?.addSubview(webView)
        #expect(panel.makeFirstResponder(webView))
        let router = router()
        #expect(router.routesNativePaletteKey(try Self.key("E", [.command, .shift], keyCode: 14), in: panel))
        #expect(!router.routesNativePaletteKey(try Self.cmdShiftP(), in: panel))
        #expect(ran.ids == ["commandPalette"])
    }

    /// No default binding, in any context, gives Cmd-P or Cmd-Shift-P to anything but the native
    /// palettes, so a new web view (or a new action scoped to one) cannot take them back.
    @Test func onlyTheNativePalettesHaveCmdPAndCmdShiftPByDefault() {
        let reserved: Set<Shortcut> = [Shortcut("p", modifiers: [.command]), Shortcut("p", modifiers: [.command, .shift])]
        let owners = RegistryKeyBindings(registry).table.entries
            .filter { $0.source == .default && $0.keys.count == 1 && reserved.contains($0.keys[0]) }
            .map(\.command)
        #expect(!owners.isEmpty)
        #expect(Set(owners).isSubset(of: KeyRouter.nativePaletteActions), "\(owners)")
    }
}
