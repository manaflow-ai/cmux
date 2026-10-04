import AppKit
import CmuxNextActions
import Testing

/// Chords of up to four keys in the binding table (R59, K2): what each next
/// key under an armed prefix does, for the which-key overlay, and app and
/// user layers (keybindings.json) that add sequences after the defaults.
@MainActor
@Suite struct KeyChordSequenceTests {
    static let ctrlK = Shortcut("k", modifiers: [.control])
    static let s = Shortcut("s", modifiers: [])
    static let x = Shortcut("x", modifiers: [])
    static let y = Shortcut("y", modifiers: [])
    static let terminal = KeyContext([KeyContext.surfaceKind: .string("terminal"), "terminalFocused": .bool(true)])
    static let page = KeyContext([KeyContext.surfaceKind: .string("page"), "browserFocused": .bool(true)])

    static let table = KeyBindingTable([
        KeyBinding(keys: [ctrlK, s], command: "save"),
        KeyBinding(keys: [ctrlK, x, y], command: "deep", when: .has("terminalFocused")),
        KeyBinding(keys: [ctrlK, x, s, y], command: "deepest"),
        KeyBinding(keys: [ctrlK, Shortcut("1", modifiers: [])], command: "select", argument: "1"),
        KeyBinding(keys: [ctrlK, Shortcut("2", modifiers: [])], command: "select", argument: "2"),
        KeyBinding(keys: [ctrlK, x, s, y, s], command: "tooLong"),
    ])

    @Test func sequencesUpToFourKeysResolveAndLongerOnesNever() {
        let all = { (_: ActionID) in true }
        #expect(Self.table.resolve([Self.ctrlK, Self.x, Self.y], in: Self.terminal, isRunnable: all).winner?.command == "deep")
        #expect(Self.table.resolve([Self.ctrlK, Self.x, Self.y], in: Self.page, isRunnable: all).winner == nil)
        #expect(Self.table.resolve([Self.ctrlK, Self.x, Self.s, Self.y], in: Self.page, isRunnable: all).winner?.command == "deepest")
        #expect(Self.table.resolve([Self.ctrlK, Self.x, Self.s, Self.y, Self.s], in: Self.page, isRunnable: all).winner == nil)
        #expect(Self.table.continues([Self.ctrlK, Self.x, Self.s], in: Self.page, isRunnable: all))
        #expect(!Self.table.continues([Self.ctrlK, Self.x, Self.s, Self.y], in: Self.page, isRunnable: all), "a fifth key never arms")
    }

    /// Every key under a prefix, once: what it runs now (or the first entry
    /// when none can run), whether more keys follow it, and whether pressing
    /// it does anything here. A numbered family lists its `1` once.
    @Test func nextKeysListEveryKeyUnderAPrefixOnce() {
        let runnable = { (id: ActionID) in id != "save" }
        let next = Self.table.nextKeys(after: [Self.ctrlK], in: Self.page, isRunnable: runnable)
        #expect(next.map(\.key) == [Shortcut("1", modifiers: []), Self.s, Self.x], "ordered by key")
        let save = next.first { $0.key == Self.s }
        #expect(save?.binding?.command == "save")
        #expect(save?.continues == false)
        #expect(save?.isRunnable == false, "its action cannot run")
        let x = next.first { $0.key == Self.x }
        #expect(x?.binding == nil, "nothing runs on the second key itself")
        #expect(x?.continues == true)
        #expect(x?.isRunnable == true, "deepest can run in a page")
        let digit = next.first { $0.key == Shortcut("1", modifiers: []) }
        #expect(digit?.binding?.command == "select")
        #expect(digit?.binding?.argument == "1")
        let deeper = Self.table.nextKeys(after: [Self.ctrlK, Self.x], in: Self.page, isRunnable: runnable)
        #expect(deeper.map(\.key) == [Self.s, Self.y])
        #expect(deeper.first { $0.key == Self.y }?.isRunnable == false, "deep needs a terminal")
        #expect(deeper.first { $0.key == Self.s }?.continues == true)
    }

    /// App entries come after the defaults and user entries after cmux.json:
    /// a keybindings.json sequence wins over a default on the same keys.
    @Test func layerEntriesJoinTheTableInPrecedenceOrder() {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "save", title: "Save", defaultShortcut: Shortcut("k", modifiers: [.control]), category: .workspace),
            ActionDescriptor(id: "mine", title: "Mine", category: .workspace),
            ActionDescriptor(id: "theirs", title: "Theirs", category: .workspace),
        ])
        for id: ActionID in ["save", "mine", "theirs"] { registry.bind(id, invoke: { _ in }) }
        let all = { (_: ActionID) in true }
        registry.keyBindingLayers = KeyBindingLayers(
            app: [KeyBinding(keys: [Self.ctrlK], command: "theirs", source: .app),
                  KeyBinding(keys: [Self.ctrlK, Self.x, Self.y], command: "theirs", source: .app)],
            user: [KeyBinding(keys: [Self.ctrlK, Self.x, Self.y], command: "mine", source: .user)])
        let table = RegistryKeyBindings(registry).table
        #expect(table.resolve([Self.ctrlK], in: Self.page, isRunnable: all).winner?.command == "theirs")
        let sequence = table.resolve([Self.ctrlK, Self.x, Self.y], in: Self.page, isRunnable: all)
        #expect(sequence.winner?.command == "mine")
        #expect(sequence.candidates.map(\.verdict) == [.won, .shadowed])
        registry.keyBindingLayers = KeyBindingLayers()
        #expect(RegistryKeyBindings(registry).table.resolve([Self.ctrlK], in: Self.page, isRunnable: all).winner?.command == "save",
                "a layer change rebuilds the table")
    }
}
