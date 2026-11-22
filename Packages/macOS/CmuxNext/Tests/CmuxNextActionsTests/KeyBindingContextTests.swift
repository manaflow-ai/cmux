import AppKit
import CmuxNextActions
import Testing

/// Scoped bindings (Lawrence, 2026-10-06: "make sure we build the shortcut in
/// a generalizable way"): any binding may name the context it applies in
/// (`when`); the last entry that applies wins, scoped defaults sit after
/// the global defaults they replace, and conflicts are found per context.
/// Home's Cmd-Shift-[ / ] use it; tab switching elsewhere is unchanged.
@MainActor
@Suite struct KeyBindingContextTests {
    static let next = Shortcut("]", modifiers: [.command, .shift])
    static let previous = Shortcut("[", modifiers: [.command, .shift])
    static let home = KeyContext([KeyContext.surfaceKind: .string("home"), KeyContext.topPage: .string("home")])
    /// A Home conversation tab inside a workspace: surfaceKind home, no top page.
    static let conversationTab = KeyContext([KeyContext.surfaceKind: .string("home")])
    static let terminal = KeyContext([KeyContext.surfaceKind: .string("terminal"), "terminalFocused": .bool(true)])
    static let isHome = WhenClause.equals(KeyContext.topPage, .string("home"))

    /// A scoped entry after the global one wins in its context; elsewhere the global key runs.
    @Test func aScopedEntryAfterAGlobalOneWinsInItsContext() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.next], command: "nextSurface"),
            KeyBinding(keys: [Self.next], command: "home.next", when: Self.isHome),
        ])
        #expect(table.resolve([Self.next], in: Self.home) { _ in true }.winner?.command == "home.next")
        #expect(table.resolve([Self.next], in: Self.terminal) { _ in true }.winner?.command == "nextSurface")
    }

    @Test func aLaterLayerStillWins() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.next], command: "home.next", when: Self.isHome),
            KeyBinding(keys: [Self.next], command: "mine", source: .user),
        ])
        #expect(table.resolve([Self.next], in: Self.home) { _ in true }.winner?.command == "mine",
                "a user's global binding overrides a default in every context")
    }

    @Test func conflictsAreFoundPerContext() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.next], command: "nextSurface"),
            KeyBinding(keys: [Self.next], command: "home.next", when: Self.isHome),
            KeyBinding(keys: [Self.next], command: "home.other", when: Self.isHome),
            KeyBinding(keys: [Self.previous], command: "prevSurface"),
            KeyBinding(keys: [Self.previous], command: "home.previous", when: Self.isHome),
        ])
        let groups = table.conflicts().map { Set($0.map(\.command.rawValue)) }
        #expect(groups == [["home.next", "home.other"]], "a context entry over a global one is no conflict")
    }

    /// The real catalog: Cmd-Shift-[ / ] move between conversations on Home
    /// and switch tabs in a terminal workspace.
    @Test func homeMovesBetweenConversationsAndATerminalSwitchesTabs() {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["home.previousConversation", "home.nextConversation", "nextSurface", "prevSurface"] {
            registry.bind(id, invoke: { _ in })
        }
        let table = RegistryKeyBindings(registry).table
        let winner = { (keys: Shortcut, context: KeyContext) in table.resolve([keys], in: context) { _ in true }.winner?.command }
        #expect(winner(Self.next, Self.home) == "home.nextConversation")
        #expect(winner(Self.previous, Self.home) == "home.previousConversation")
        #expect(winner(Self.next, Self.terminal) == "nextSurface")
        #expect(winner(Self.previous, Self.terminal) == "prevSurface")
        #expect(winner(Self.next, Self.conversationTab) == "nextSurface", "a conversation tab in a workspace switches tabs")
        #expect(table.conflicts().isEmpty, "\(table.conflicts().map { $0.map(\.command.rawValue) })")
    }
}
