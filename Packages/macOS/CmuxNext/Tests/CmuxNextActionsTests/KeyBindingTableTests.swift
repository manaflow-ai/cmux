import AppKit
import CmuxNextActions
import Testing

/// `resolveWinner` (the key-down path) picks the entry `resolve` names as winner,
/// on the shipped table for every key, in many contexts, with several runnable and accept rules.
@MainActor @Suite struct KeyBindingTableTests {
    nonisolated static let cmdK = Shortcut("k", modifiers: [.command])
    nonisolated static let cmdJ = Shortcut("j", modifiers: [.command])
    nonisolated static let terminal = KeyContext(["terminalFocused": .bool(true)])

    @Test func resolveWinnerMatchesResolveOnTheCatalog() {
        let table = CompiledWhenTests.catalogTable()
        let keys = Array(Set(table.entries.map(\.keys)))
        #expect(keys.count > 50)
        var fuzz = WhenFuzz(seed: 0x7AB1_E055, clauses: table.entries.compactMap(\.when))
        let contexts = WhenFuzz.namedContexts + (0..<24).map { _ in fuzz.context() }
        let runnable: [(ActionID) -> Bool] = [{ _ in true }, { $0.rawValue.utf8.count % 3 != 0 }]
        let accepts: [(KeyBinding) -> Bool] = [{ _ in true }, { !$0.source.isGhostty }, { $0.source != .ghosttyFallback }]
        var mismatches = 0
        for context in contexts {
            let input = CompiledWhen.Input(context)
            for isRunnable in runnable {
                for accept in accepts {
                    for sequence in keys {
                        let expected = table.resolve(sequence, in: context, isRunnable: isRunnable, accepts: accept).winner
                        let winner = table.resolveWinner(sequence, in: input, isRunnable: isRunnable, accepts: accept)
                        if winner != expected {
                            mismatches += 1
                            Issue.record("\(sequence): \(String(describing: winner?.command)) != \(String(describing: expected?.command)) in \(context.values)")
                        }
                    }
                }
            }
            if mismatches > 5 { break }
        }
    }

    /// An entry whose `when` holds but cannot run ends the search; one with no `when` lets it go on (R88).
    @Test func aScopedEntryThatCannotRunBlocksTheKey() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.cmdK], command: "general"),
            KeyBinding(keys: [Self.cmdK], command: "scoped", when: .has("terminalFocused")),
        ])
        let notScoped: (ActionID) -> Bool = { $0 != "scoped" }
        #expect(table.resolveWinner(CollectionOfOne(Self.cmdK), in: Self.terminal, isRunnable: notScoped) == nil)
        #expect(table.resolve([Self.cmdK], in: Self.terminal, isRunnable: notScoped).winner == nil)
        #expect(table.resolveWinner(CollectionOfOne(Self.cmdK), in: KeyContext(), isRunnable: notScoped)?.command == "general")
        #expect(table.resolveWinner(CollectionOfOne(Self.cmdK), in: Self.terminal, isRunnable: { _ in true })?.command == "scoped")
    }

    @Test func anUnscopedEntryThatCannotRunFallsThrough() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.cmdK], command: "first"),
            KeyBinding(keys: [Self.cmdK], command: "disabled"),
        ])
        let winner = table.resolveWinner(CollectionOfOne(Self.cmdK), in: KeyContext(), isRunnable: { $0 != "disabled" })
        #expect(winner?.command == "first")
        #expect(table.resolve([Self.cmdK], in: KeyContext(), isRunnable: { $0 != "disabled" }).winner == winner)
    }

    @Test func acceptsLeavesEntriesOut() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.cmdK], command: "default"),
            KeyBinding(keys: [Self.cmdK], command: "ghostty", source: .ghosttyFallback),
        ].sorted { $0.source < $1.source })
        #expect(table.resolveWinner(CollectionOfOne(Self.cmdK), in: KeyContext(), isRunnable: { _ in true })?.command == "default")
        #expect(table.resolveWinner(CollectionOfOne(Self.cmdK), in: KeyContext(), isRunnable: { _ in true },
                                    accepts: { $0.source != .default })?.command == "ghostty")
    }

    /// A key sequence matches only an entry with exactly those keys.
    @Test func sequencesMatchWholeKeys() {
        let x = Shortcut("x", modifiers: [])
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.cmdJ], command: "single"),
            KeyBinding(keys: [Self.cmdJ, x], command: "chord"),
        ])
        #expect(table.resolveWinner([Self.cmdJ, x], in: KeyContext(), isRunnable: { _ in true })?.command == "chord")
        #expect(table.resolveWinner(CollectionOfOne(Self.cmdJ), in: KeyContext(), isRunnable: { _ in true })?.command == "single")
        #expect(table.resolveWinner(CollectionOfOne(x), in: KeyContext(), isRunnable: { _ in true }) == nil)
        #expect(table.resolveWinner(EmptyCollection<Shortcut>(), in: KeyContext(), isRunnable: { _ in true }) == nil)
        #expect(table.continues([Self.cmdJ], in: KeyContext(), isRunnable: { _ in true }))
        #expect(!table.continues([Self.cmdJ], in: KeyContext(), isRunnable: { $0 != "chord" }))
    }

    /// The readings of one key-down are held inline: none, one, or two different shortcuts.
    @Test func shortcutReadings() {
        let brace = Shortcut("}", modifiers: [.shift, .command]), bracket = Shortcut("]", modifiers: [.shift, .command])
        #expect(ShortcutReadings().isEmpty)
        #expect(Array(ShortcutReadings(brace)) == [brace])
        #expect(Array(ShortcutReadings(brace, brace)) == [brace])
        #expect(Array(ShortcutReadings(brace, bracket)) == [brace, bracket])
        #expect(ShortcutReadings(brace, bracket).contains(bracket))
    }

    /// The chord step's in-place sequence reads as the armed keys then the reading, and the
    /// leader check agrees with `entries(after:)`.
    @Test func keysThenOneAndHasEntries() {
        let x = Shortcut("x", modifiers: [])
        #expect(Array(KeyBindingTable.KeysThenOne([], Self.cmdJ)) == [Self.cmdJ])
        #expect(Array(KeyBindingTable.KeysThenOne([Self.cmdJ], x)) == [Self.cmdJ, x])
        #expect(KeyBindingTable.KeysThenOne([Self.cmdJ, x], Self.cmdK).count == 3)
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.cmdK], command: "single"),
            KeyBinding(keys: [Self.cmdJ, x], command: "chord", when: .has("terminalFocused")),
        ])
        for prefix in [[Self.cmdJ], [Self.cmdK], [Self.cmdJ, x], [x]] {
            #expect(table.hasEntries(after: prefix) == !table.entries(after: prefix).isEmpty, "\(prefix)")
        }
        #expect(table.hasEntries(after: CollectionOfOne(Self.cmdJ)))
        // The leader arms even where its only entry cannot run; the chord then completes in a terminal.
        let always: (ActionID) -> Bool = { _ in true }
        #expect(table.step(after: [], readings: ShortcutReadings(Self.cmdJ), in: KeyContext(), isRunnable: always) == .extend(Self.cmdJ))
        #expect(table.step(after: [Self.cmdJ], readings: ShortcutReadings(x), in: Self.terminal, isRunnable: always).runs == "chord")
        #expect(table.step(after: [], readings: ShortcutReadings(Self.cmdK), in: KeyContext(), isRunnable: always).runs == "single")
    }
}

private extension KeyBindingTable.SequenceStep {
    /// The command a `.run` step runs.
    var runs: ActionID? {
        if case .run(let binding) = self { return binding.command }
        return nil
    }
}
