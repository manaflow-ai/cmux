import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Chords of up to four keys at the key router (`ChordTracker`, R59 K2):
/// each key of a longer sequence keeps the chord armed, the last one runs
/// it, Escape cancels at any depth, and the which-key overlay lists the
/// next keys of every armed prefix, not only the Cmd-J leader's.
@MainActor
struct MultiKeyChordRoutingTests {
    static let ctrlK = ShortcutChordRoutingTests.key(40, "k", typing: "\u{B}", .control)
    static let x = ShortcutChordRoutingTests.key(7, "x")
    static let y = ShortcutChordRoutingTests.key(16, "y")
    static let s = ShortcutChordRoutingTests.key(1, "s")
    static let escape = LeaderChordRoutingTests.escape
    static let k = Shortcut("k", modifiers: [.control])

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "save", title: "Save All", category: .workspace),
            ActionDescriptor(id: "deep", title: "Deep", category: .workspace),
            ActionDescriptor(id: "deepest", title: "Deepest", category: .workspace),
        ])
        for id: ActionID in ["save", "deep", "deepest"] { registry.bind(id, invoke: { _ in }) }
        let plain = { (key: String) in Shortcut(key, modifiers: []) }
        registry.setKeyBindingLayers(KeyBindingLayers(user: [
            KeyBinding(keys: [k, plain("s")], command: "save", source: .user),
            KeyBinding(keys: [k, plain("x"), plain("y")], command: "deep", source: .user),
            KeyBinding(keys: [k, plain("x"), plain("s"), plain("y")], command: "deepest", source: .user),
        ]))
        return registry
    }

    static func step(_ chords: inout ChordTracker, _ event: NSEvent, _ registry: ActionRegistry, window: NSObject) -> ChordTracker.Step {
        chords.step(event, window: ObjectIdentifier(window), registry: registry) { true }
    }

    @Test func eachKeyOfALongerChordArmsUntilTheLastRuns() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        #expect(Self.step(&chords, Self.ctrlK, registry, window: window) == .armed)
        #expect(chords.armedKeys == [Self.k])
        #expect(Self.step(&chords, Self.x, registry, window: window) == .armed)
        #expect(chords.armedKeys == [Self.k, Shortcut("x", modifiers: [])])
        #expect(Self.step(&chords, Self.y, registry, window: window) == .run("deep", argument: nil))
        #expect(!chords.isPending)

        _ = Self.step(&chords, Self.ctrlK, registry, window: window)
        _ = Self.step(&chords, Self.x, registry, window: window)
        #expect(Self.step(&chords, Self.s, registry, window: window) == .armed)
        #expect(Self.step(&chords, Self.y, registry, window: window) == .run("deepest", argument: nil))
        #expect(Self.step(&chords, Self.y, registry, window: window) == .pass, "a lone Y types")
    }

    @Test func escapeCancelsAtAnyDepthAndAnotherKeyEndsTheChord() {
        let registry = Self.registry(), window = NSObject()
        var chords = ChordTracker()
        _ = Self.step(&chords, Self.ctrlK, registry, window: window)
        _ = Self.step(&chords, Self.x, registry, window: window)
        #expect(Self.step(&chords, Self.escape, registry, window: window) == .dismissed, "Escape never reaches the view")
        #expect(!chords.isPending)
        _ = Self.step(&chords, Self.ctrlK, registry, window: window)
        _ = Self.step(&chords, Self.x, registry, window: window)
        #expect(Self.step(&chords, Self.x, registry, window: window) == .mismatch, "an unbound key goes on to the view")
        #expect(!chords.isPending)
    }

    /// The overlay rows for a prefix that is not the leader: a key that
    /// runs an action shows its title, a key that leads to more keys says so.
    @Test func whichKeyListsTheNextKeysOfAnyPrefix() {
        let registry = Self.registry()
        let table = RegistryKeyBindings(registry).table
        let rows = WhichKeyListing.rows(after: [Self.k], table: table, context: KeyContext(bits: []),
                                        isRunnable: { _ in true }, registry: registry)
        #expect(rows.map(\.key) == ["S", "X"])
        #expect(rows.first?.title == "Save All")
        #expect(rows.last?.title == WhichKeyStrings.moreKeys)
        let deeper = WhichKeyListing.rows(after: [Self.k, Shortcut("x", modifiers: [])], table: table, context: KeyContext(bits: []),
                                          isRunnable: { _ in true }, registry: registry)
        #expect(deeper.map(\.title) == [WhichKeyStrings.moreKeys, "Deep"])
    }
}
