import AppKit
import CmuxNextActions
import Testing

/// Space keys that clash with nothing (Lawrence 14223 follow-up). Asked: Ctrl-Cmd-Left / Right and
/// Ctrl-Cmd-1…9. Both clash in cmux (Ghostty's reserved pane resize, Focus Pane by Number), so the
/// nearest free combo adds Option: Ctrl-Opt-Cmd-Left / Right step spaces, Ctrl-Opt-Cmd-1…9 pick one
/// (plans/cmux-next/spaces-overhaul-DESIGN.md "Keys"). The old keys (Opt-Cmd-[ / ], Ctrl-Opt-1…9)
/// stay as aliases; every key follows its action's rebind. Ctrl-Opt-Cmd-H / L became the shown keys on
/// Nov 7, with the arrows kept as aliases.
@MainActor @Suite struct SpaceKeysTests {
    nonisolated static let terminal: [String: KeyContextValue] = [KeyContext.surfaceKind: .string("terminal")]
    nonisolated static let page: [String: KeyContextValue] = [KeyContext.surfaceKind: .string("page")]
    nonisolated static let agent: [String: KeyContextValue] = [KeyContext.surfaceKind: .string("agent")]
    static let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
    static let left = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
    static let hyper: NSEvent.ModifierFlags = [.control, .option, .command]

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return registry
    }

    static func winner(_ key: Shortcut, _ context: [String: KeyContextValue], registry: ActionRegistry = registry()) -> KeyBinding? {
        RegistryKeyBindings(registry).table.resolve([key], in: KeyContext(context), isRunnable: { _ in true }).winner
    }

    @Test(arguments: [terminal, page, agent])
    func ctrlOptCmdArrowsStepSpaces(context: [String: KeyContextValue]) {
        #expect(Self.winner(Shortcut(Self.right, modifiers: Self.hyper), context)?.command == "space.next")
        #expect(Self.winner(Shortcut(Self.left, modifiers: Self.hyper), context)?.command == "space.previous")
    }

    /// Ctrl-Opt-Cmd-H / L step spaces, vim's left / right (Lawrence, Nov 7: "do ctrl option cmd hl
    /// for navigating spaces"). They are the catalog keys, so menus, tooltips and the palette show them.
    @Test(arguments: [terminal, page, agent])
    func ctrlOptCmdHLStepSpaces(context: [String: KeyContextValue]) {
        #expect(Self.winner(Shortcut("l", modifiers: Self.hyper), context)?.command == "space.next")
        #expect(Self.winner(Shortcut("h", modifiers: Self.hyper), context)?.command == "space.previous")
    }

    @Test func theShownSpaceKeysAreCtrlOptCmdHL() {
        let registry = Self.registry()
        #expect(registry.effectiveShortcut(for: "space.next") == Shortcut("l", modifiers: [.control, .option, .command]))
        #expect(registry.effectiveShortcut(for: "space.previous") == Shortcut("h", modifiers: [.control, .option, .command]))
    }

    /// A rebind takes H / L with it, and the arrow aliases too.
    @Test func aRebindDropsCtrlOptCmdHL() {
        let registry = Self.registry()
        registry.setShortcutOverride(Shortcut("p", modifiers: [.control, .option, .command]), for: "space.previous")
        #expect(Self.winner(Shortcut("h", modifiers: Self.hyper), Self.terminal, registry: registry)?.command != "space.previous")
        #expect(Self.winner(Shortcut(Self.left, modifiers: Self.hyper), Self.terminal, registry: registry)?.command != "space.previous")
        #expect(Self.winner(Shortcut("p", modifiers: Self.hyper), Self.terminal, registry: registry)?.command == "space.previous")
    }

    @Test(arguments: [terminal, page, agent])
    func ctrlOptCmdDigitsPickASpace(context: [String: KeyContextValue]) {
        for digit in 1...9 {
            let winner = Self.winner(Shortcut(String(digit), modifiers: Self.hyper), context)
            #expect(winner?.command == "space.selectByNumber", "⌃⌥⌘\(digit)")
            #expect(winner?.argument == String(digit))
        }
    }

    /// The keys a person already learned keep working.
    @Test func theOldSpaceKeysStillWork() {
        #expect(Self.winner(Shortcut("]", modifiers: [.option, .command]), Self.terminal)?.command == "space.next")
        #expect(Self.winner(Shortcut("[", modifiers: [.option, .command]), Self.terminal)?.command == "space.previous")
        #expect(Self.winner(Shortcut("3", modifiers: [.control, .option]), Self.terminal)?.command == "space.selectByNumber")
    }

    /// The keys the user asked for keep their cmux meaning (the clash that moved the defaults).
    @Test func ctrlCmdArrowsAndDigitsKeepTheirPaneMeaning() {
        #expect(Self.winner(Shortcut(Self.right, modifiers: [.control, .command]), Self.terminal)?.command == "resizePaneRight")
        #expect(Self.winner(Shortcut("2", modifiers: [.control, .command]), Self.terminal)?.command == "focusPaneByNumber")
    }

    /// A rebind in Settings or cmux.json takes every default key of the action with it.
    @Test func aRebindDropsTheDefaultsAndTheAliases() {
        let registry = Self.registry()
        registry.setShortcutOverride(Shortcut("j", modifiers: [.control, .option, .command]), for: "space.next")
        #expect(Self.winner(Shortcut(Self.right, modifiers: Self.hyper), Self.terminal, registry: registry)?.command != "space.next")
        #expect(Self.winner(Shortcut("]", modifiers: [.option, .command]), Self.terminal, registry: registry)?.command != "space.next")
        #expect(Self.winner(Shortcut("j", modifiers: Self.hyper), Self.terminal, registry: registry)?.command == "space.next")
    }

    /// Mission Control owns Ctrl-arrows and Ctrl-digits (Switch to Desktop, Move a Space): no space key
    /// is Ctrl alone.
    @Test func noSpaceKeyIsAMissionControlKey() {
        let space: Set<ActionID> = ["space.next", "space.previous", "space.selectByNumber"]
        let keys = RegistryKeyBindings(Self.registry()).table.entries.filter { space.contains($0.command) }.flatMap(\.keys)
        #expect(!keys.isEmpty)
        for key in keys {
            #expect(key.modifiers != [.control], "\(key) is a Mission Control key")
        }
    }
}

/// No two shipped bindings collide: two default entries on the same keys under the same `when`
/// clause that run different actions mean one of them can never run (the later wins silently).
@MainActor @Suite struct KeyBindingCollisionTests {
    struct Slot: Hashable {
        var keys: [Shortcut]
        var when: WhenClause?
    }

    @Test func noTwoShippedBindingsShareKeysAndScope() {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        let shipped = RegistryKeyBindings(registry).table.entries.filter { $0.source == .default || $0.source == .app }
        var commands: [Slot: Set<String>] = [:]
        for entry in shipped {
            commands[Slot(keys: entry.keys, when: entry.when), default: []].insert("\(entry.command.rawValue)|\(entry.argument ?? "")")
        }
        let collisions = commands.filter { $0.value.count > 1 }.map { "\($0.key.keys): \($0.value.sorted())" }.sorted()
        #expect(collisions.isEmpty, "\(collisions.joined(separator: "\n"))")
    }
}
