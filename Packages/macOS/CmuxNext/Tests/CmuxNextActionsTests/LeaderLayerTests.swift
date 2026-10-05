import AppKit
import CmuxNextActions
import Testing

/// The Cmd-J leader layer (`LeaderLayer`): its default chords live in the
/// catalog, add to an action's own single key, and follow cmux.json like
/// any chord (a user chord replaces them, a single key or an unbind drops
/// them).
@MainActor
@Suite struct LeaderLayerTests {
    static let j = Shortcut("j", modifiers: [])
    static let s = Shortcut("s", modifiers: [])
    static let questionMark = Shortcut("/", modifiers: [.shift])

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for (id, _) in LeaderLayer.defaultChords { registry.bind(id) {} }
        return registry
    }

    @Test func theLeaderIsCommandJ() {
        #expect(LeaderLayer.prefix == Shortcut("j", modifiers: [.command]))
    }

    @Test func theCatalogCarriesTheDefaultChords() {
        let registry = ActionRegistry.standard()
        #expect(registry.effectiveChord(for: "terminal.scrollToSelection") == ShortcutChord(LeaderLayer.prefix, Self.j))
        #expect(registry.effectiveChord(for: "palette.newAgentChat") == ShortcutChord(LeaderLayer.prefix, Self.s))
        #expect(registry.effectiveChord(for: "palette.searchShortcuts") == ShortcutChord(LeaderLayer.prefix, Self.questionMark))
        for (id, _) in LeaderLayer.defaultChords {
            #expect(ActionCatalog.all.contains { $0.id == id }, "\(id)")
        }
    }

    /// New Agent Chat keeps Cmd-I; the leader chord is a second way in.
    /// An action with only a chord shows the chord.
    @Test func aDefaultChordAddsToTheSingleKey() {
        let registry = Self.registry()
        #expect(registry.effectiveShortcut(for: "palette.newAgentChat") == Shortcut("i", modifiers: [.command]))
        #expect(registry.resolve(Shortcut("i", modifiers: [.command]))?.id == "palette.newAgentChat")
        #expect(registry.shortcutDisplay(for: "palette.newAgentChat") == "⌘I")
        #expect(registry.shortcutDisplay(for: "terminal.scrollToSelection") == "⌘J J")
        #expect(registry.shortcutKeycaps(for: "terminal.scrollToSelection") == ["⌘", "J", "J"])
        #expect(registry.shortcutDisplay(for: "palette.searchShortcuts") == "⌘J ⇧/")
    }

    @Test func leaderChordsResolveAfterThePrefix() {
        let registry = Self.registry()
        #expect(registry.startsChord(LeaderLayer.prefix))
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Self.j)?.id == "terminal.scrollToSelection")
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Self.s)?.id == "palette.newAgentChat")
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Self.questionMark)?.id == "palette.searchShortcuts")
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Shortcut("q", modifiers: [])) == nil)
    }

    /// `"terminal.scrollToSelection": ["cmd+j", "k"]` moves it to K.
    @Test func aUserChordReplacesTheDefaultChord() {
        let registry = Self.registry()
        let k = Shortcut("k", modifiers: [])
        registry.setChordOverride(ShortcutChord(LeaderLayer.prefix, k), for: "terminal.scrollToSelection")
        #expect(registry.resolveChord(after: LeaderLayer.prefix, k)?.id == "terminal.scrollToSelection")
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Self.j) == nil)
        #expect(registry.shortcutDisplay(for: "terminal.scrollToSelection") == "⌘J K")

        registry.removeShortcutOverride(for: "terminal.scrollToSelection")
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Self.j)?.id == "terminal.scrollToSelection")
    }

    /// A single key in cmux.json replaces the action's binding, chord
    /// included; `null` unbinds both.
    @Test func aSingleKeyOrAnUnbindDropsTheDefaultChord() {
        let registry = Self.registry()
        registry.setShortcutOverride(Shortcut("y", modifiers: [.command, .option]), for: "palette.newAgentChat")
        #expect(registry.effectiveChord(for: "palette.newAgentChat") == nil)
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Self.s) == nil)

        registry.setShortcutOverride(nil, for: "terminal.scrollToSelection")
        #expect(registry.effectiveChord(for: "terminal.scrollToSelection") == nil)
        #expect(registry.shortcutDisplay(for: "terminal.scrollToSelection") == nil)
        #expect(registry.resolveChord(after: LeaderLayer.prefix, Self.j) == nil)

        registry.removeShortcutOverride(for: "terminal.scrollToSelection")
        #expect(registry.effectiveChord(for: "terminal.scrollToSelection") == ShortcutChord(LeaderLayer.prefix, Self.j))
    }

    /// `"toggleSidebar": "cmd+j"` in cmux.json: the user's own Cmd-J runs,
    /// and the default leader chords step aside.
    @Test func aUsersOwnCommandJWins() {
        let registry = Self.registry()
        registry.bind("toggleSidebar") {}
        registry.setShortcutOverride(LeaderLayer.prefix, for: "toggleSidebar")
        #expect(registry.resolve(LeaderLayer.prefix)?.id == "toggleSidebar")
        #expect(registry.effectiveChord(for: "terminal.scrollToSelection") == nil)
        #expect(!LeaderLayer(registry: registry).hasChords())

        // A chord the user put under Cmd-J themselves still counts.
        let k = Shortcut("k", modifiers: [])
        registry.setChordOverride(ShortcutChord(LeaderLayer.prefix, k), for: "terminal.scrollToSelection")
        #expect(registry.resolveChord(after: LeaderLayer.prefix, k)?.id == "terminal.scrollToSelection")
    }

    /// What the which-key overlay lists: every binding under the prefix,
    /// performable or not.
    @Test func chordsAfterThePrefixListEveryLeaderBinding() {
        let registry = ActionRegistry.standard()
        let leader = LeaderLayer(registry: registry)
        let bindings = leader.chords()
        #expect(Set(bindings.map(\.id)) == Set(LeaderLayer.defaultChords.map { $0.id }))
        #expect(bindings.contains(ChordBinding(second: Self.j, id: "terminal.scrollToSelection")))
        #expect(leader.chords(after: Shortcut("b", modifiers: [.control])).isEmpty)
        #expect(leader.hasChords())
    }
}
