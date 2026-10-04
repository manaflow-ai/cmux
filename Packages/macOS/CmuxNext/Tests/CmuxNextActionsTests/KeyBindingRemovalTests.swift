import AppKit
import CmuxNextActions
import Testing

/// Negative entries (`"command": "-nextSurface"` in keybindings.json, R59):
/// a removal takes out the default and app entries that match its command,
/// its keys and its `when`, and leaves the action's other keys alone.
@MainActor
@Suite struct KeyBindingRemovalTests {
    static let ctrlTab = Shortcut("\t", modifiers: [.control])
    static let ctrlPageDown = Shortcut(KeyBindingDefaults.pageDown, modifiers: [.control])
    static let nextKey = Shortcut("]", modifiers: [.command, .shift])
    static let agent = KeyContext([KeyContext.surfaceKind: .string("agent")])
    static let copyMode = KeyContext([KeyContext.surfaceKind: .string("terminal"), KeyContext.terminalCopyMode: .bool(true)])
    static let all = { (_: ActionID) in true }

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "nextSurface", title: "Next Tab", defaultShortcut: nextKey, category: .tab),
            ActionDescriptor(id: "prevSurface", title: "Previous Tab", defaultShortcut: Shortcut("[", modifiers: [.command, .shift]),
                             category: .tab),
        ])
        for id: ActionID in ["nextSurface", "prevSurface"] { registry.bind(id, invoke: { _ in }) }
        return registry
    }

    static func winner(_ registry: ActionRegistry, _ keys: [Shortcut], _ context: KeyContext) -> ActionID? {
        RegistryKeyBindings(registry).table.resolve(keys, in: context, isRunnable: all).winner?.command
    }

    /// Key + when: only the Ctrl-Tab entry outside a terminal goes; copy
    /// mode's Ctrl-Tab, Ctrl-PageDown and Cmd-Shift-] stay.
    @Test func aRemovalTakesOutOneDefaultByKeyAndWhen() {
        let registry = Self.registry()
        let issues = registry.setKeyBindingLayers(KeyBindingLayers(removals: [
            KeyBindingRemoval(command: "nextSurface", keys: [Self.ctrlTab], when: .exactly(KeyBindingDefaults.notTerminal)),
        ]))
        #expect(issues.isEmpty)
        #expect(Self.winner(registry, [Self.ctrlTab], Self.agent) == nil)
        #expect(Self.winner(registry, [Self.ctrlTab], Self.copyMode) == "nextSurface")
        #expect(Self.winner(registry, [Self.ctrlPageDown], Self.agent) == "nextSurface")
        #expect(Self.winner(registry, [Self.nextKey], Self.agent) == "nextSurface")
        #expect(Self.winner(registry, [Shortcut("\t", modifiers: [.control, .shift])], Self.agent) == "prevSurface")
    }

    /// No `when`: every entry of the command on that key goes. No keys:
    /// every key of the command goes, as an unbind would.
    @Test func anOmittedWhenOrKeyMatchesEveryEntry() {
        let registry = Self.registry()
        registry.setKeyBindingLayers(KeyBindingLayers(removals: [KeyBindingRemoval(command: "nextSurface", keys: [Self.ctrlTab])]))
        #expect(Self.winner(registry, [Self.ctrlTab], Self.agent) == nil)
        #expect(Self.winner(registry, [Self.ctrlTab], Self.copyMode) == nil)
        #expect(Self.winner(registry, [Self.nextKey], Self.agent) == "nextSurface")

        registry.setKeyBindingLayers(KeyBindingLayers(removals: [KeyBindingRemoval(command: "nextSurface")]))
        #expect(Self.winner(registry, [Self.nextKey], Self.agent) == nil)
        #expect(Self.winner(registry, [Self.ctrlPageDown], Self.agent) == nil)
        #expect(Self.winner(registry, [Shortcut("[", modifiers: [.command, .shift])], Self.agent) == "prevSurface")
    }

    /// `when` must be equal, not merely overlapping: a different clause
    /// removes nothing. App entries are removable; user entries are not
    /// (the user deletes their own line instead).
    @Test func removalsMatchExactlyAndSpareUserEntries() {
        let registry = Self.registry()
        registry.setKeyBindingLayers(KeyBindingLayers(
            app: [KeyBinding(keys: [Shortcut("n", modifiers: [.control])], command: "nextSurface", source: .app)],
            user: [KeyBinding(keys: [Shortcut("m", modifiers: [.control])], command: "nextSurface", source: .user)],
            removals: [
                KeyBindingRemoval(command: "nextSurface", keys: [Self.ctrlTab], when: .exactly(.has("terminalFocused"))),
                KeyBindingRemoval(command: "nextSurface", keys: [Shortcut("n", modifiers: [.control])]),
                KeyBindingRemoval(command: "nextSurface", keys: [Shortcut("m", modifiers: [.control])]),
            ]))
        #expect(Self.winner(registry, [Self.ctrlTab], Self.agent) == "nextSurface")
        #expect(Self.winner(registry, [Shortcut("n", modifiers: [.control])], Self.agent) == nil)
        #expect(Self.winner(registry, [Shortcut("m", modifiers: [.control])], Self.agent) == "nextSurface")
    }

    @Test func aRemovalOfAnUnknownCommandIsAnIssue() {
        let registry = Self.registry()
        let issues = registry.setKeyBindingLayers(KeyBindingLayers(removals: [KeyBindingRemoval(command: "nope")]))
        #expect(issues == [KeyBindingIssue(source: .user, index: 0, kind: .unknownCommand("nope"), isRemoval: true)])
        #expect(registry.keyBindingLayers.removals.isEmpty)
    }
}
