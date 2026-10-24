import AppKit
import CmuxNextActions
import Testing

/// On Home (its top page or the docked Home's tab) the tab keys move through the chat list:
/// Ctrl-Tab / Ctrl-Shift-Tab and Cmd-Shift-] / [ step it, Ctrl-1…9 pick a chat (9 the last).
/// A Chief opened as a pane tab (`surfaceKind == home`, no `topPage`), a terminal or a page keeps
/// the normal tab keys (Lawrence 2026-10-21). The binding table resolves each key in the context
/// the key router builds.
@MainActor @Suite struct HomeChatSwitchingKeyTests {
    nonisolated static let homePage: [String: KeyContextValue] = [KeyContext.topPage: .string("home"), KeyContext.surfaceKind: .string("home")]
    nonisolated static let dockedHome: [String: KeyContextValue] = [KeyContext.surfaceKind: .string("home-dock")]
    nonisolated static let chiefTab: [String: KeyContextValue] = [KeyContext.surfaceKind: .string("home")]
    nonisolated static let terminal: [String: KeyContextValue] = [KeyContext.surfaceKind: .string("terminal")]
    nonisolated static let agentTab: [String: KeyContextValue] = [KeyContext.surfaceKind: .string("agent")]

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return registry
    }

    static func winner(_ keys: Shortcut, _ context: [String: KeyContextValue], registry: ActionRegistry = registry()) -> KeyBinding? {
        RegistryKeyBindings(registry).table.resolve([keys], in: KeyContext(context), isRunnable: { _ in true }).winner
    }

    static let ctrlTab = Shortcut("\t", modifiers: [.control])
    static let ctrlShiftTab = Shortcut("\t", modifiers: [.control, .shift])
    static let cmdShiftRight = Shortcut("]", modifiers: [.command, .shift])
    static let cmdShiftLeft = Shortcut("[", modifiers: [.command, .shift])

    @Test(arguments: [homePage, dockedHome])
    func tabKeysStepHomeChats(context: [String: KeyContextValue]) {
        #expect(Self.winner(Self.ctrlTab, context)?.command == "home.nextConversation")
        #expect(Self.winner(Self.ctrlShiftTab, context)?.command == "home.previousConversation")
        #expect(Self.winner(Self.cmdShiftRight, context)?.command == "home.nextConversation")
        #expect(Self.winner(Self.cmdShiftLeft, context)?.command == "home.previousConversation")
    }

    @Test(arguments: [homePage, dockedHome])
    func ctrlDigitsPickAHomeChat(context: [String: KeyContextValue]) {
        for digit in 1...9 {
            let winner = Self.winner(Shortcut(String(digit), modifiers: [.control]), context)
            #expect(winner?.command == "home.selectConversationByNumber")
            #expect(winner?.argument == String(digit))
        }
    }

    @Test(arguments: [chiefTab, terminal, agentTab])
    func outsideHomeTheTabKeysStayTabKeys(context: [String: KeyContextValue]) {
        #expect(Self.winner(Self.ctrlTab, context)?.command == "nextSurface")
        #expect(Self.winner(Self.ctrlShiftTab, context)?.command == "prevSurface")
        #expect(Self.winner(Self.cmdShiftRight, context)?.command == "nextSurface")
        #expect(Self.winner(Self.cmdShiftLeft, context)?.command == "prevSurface")
        #expect(Self.winner(Shortcut("3", modifiers: [.control]), context)?.command == "selectSurfaceByNumber")
    }

    /// A rebind in Settings or cmux.json keeps the Home scope: it never takes the key elsewhere.
    @Test func aReboundHomeKeyStaysOnHome() {
        let registry = Self.registry()
        let key = Shortcut("j", modifiers: [.control, .option])
        registry.setShortcutOverride(key, for: "home.nextConversation")
        #expect(Self.winner(key, Self.homePage, registry: registry)?.command == "home.nextConversation")
        #expect(Self.winner(key, Self.terminal, registry: registry)?.command != "home.nextConversation")
        // The old default key goes back to the tabs on Home too.
        #expect(Self.winner(Self.ctrlTab, Self.homePage, registry: registry)?.command == "nextSurface")
    }

    /// Settings > Keyboard and the palette show the Home keys.
    @Test func theHomeKeysAreTheActionsOwnKeys() {
        let registry = Self.registry()
        #expect(registry.effectiveShortcut(for: "home.nextConversation") == Self.ctrlTab)
        #expect(registry.effectiveShortcut(for: "home.previousConversation") == Self.ctrlShiftTab)
        #expect(registry.shortcutDisplay(for: "home.selectConversationByNumber") == "⌃1…9")
    }

    /// Scoped to Home, they are not a conflict with the pane tab keys.
    @Test func homeKeysDoNotConflictWithTabKeys() {
        let conflicts = Self.registry().shortcutConflicts().flatMap { $0 }
        #expect(!conflicts.contains("home.nextConversation"))
        #expect(!conflicts.contains("home.previousConversation"))
        #expect(!conflicts.contains("home.selectConversationByNumber"))
    }
}
