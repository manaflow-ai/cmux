import AppKit
import CmuxNextActions
import Testing

/// Two-key shortcuts from cmux.json (`["ctrl+b", "c"]`): a chord replaces
/// the action's single key, resolves only after its first key, and numbered
/// families keep working as chords and when moved to another `…1` key.
@MainActor
@Suite struct ShortcutChordTests {
    static let prefix = Shortcut("b", modifiers: [.control])

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry(catalog: [
            ShortcutAssessmentTests.action("newTab", Shortcut("t")),
            ShortcutAssessmentTests.action("closeTab", Shortcut("w")),
            ShortcutAssessmentTests.action("fam", Shortcut("1"), family: .digits),
        ])
        for id: ActionID in ["newTab", "closeTab"] { registry.bind(id, invoke: { _ in }) }
        registry.bind("fam", invoke: { _ in })
        return registry
    }

    @Test func aChordReplacesTheSingleKey() {
        let registry = Self.registry()
        registry.setChordOverride(ShortcutChord(Self.prefix, Shortcut("c", modifiers: [])), for: "newTab")
        #expect(registry.effectiveShortcut(for: "newTab") == nil)
        #expect(registry.keyWinner(Shortcut("t")) == nil)
        #expect(registry.shortcutDisplay(for: "newTab") == "⌃B C")
        #expect(registry.shortcutKeycaps(for: "newTab") == ["⌃", "B", "C"])
    }

    @Test func theSecondKeyResolvesOnlyAfterTheFirst() {
        let registry = Self.registry()
        registry.setChordOverride(ShortcutChord(Self.prefix, Shortcut("c", modifiers: [])), for: "newTab")
        registry.setChordOverride(ShortcutChord(Self.prefix, Shortcut("x", modifiers: [])), for: "closeTab")
        #expect(registry.startsChord(Self.prefix))
        #expect(!registry.startsChord(Shortcut("a", modifiers: [.control])))
        #expect(registry.resolveChord(after: Self.prefix, Shortcut("c", modifiers: []))?.id == "newTab")
        #expect(registry.resolveChord(after: Self.prefix, Shortcut("x", modifiers: []))?.id == "closeTab")
        #expect(registry.resolveChord(after: Self.prefix, Shortcut("q", modifiers: [])) == nil)
        #expect(registry.resolveChord(after: Shortcut("a", modifiers: [.control]), Shortcut("c", modifiers: [])) == nil)
        #expect(registry.keyWinner(Shortcut("c", modifiers: [])) == nil, "a chord's second key alone is no shortcut")
    }

    @Test func aChordOfAnUnavailableActionDoesNotArm() {
        let registry = ActionRegistry(catalog: [ShortcutAssessmentTests.action("newTab", Shortcut("t"))])
        registry.setChordOverride(ShortcutChord(Self.prefix, Shortcut("c", modifiers: [])), for: "newTab")
        #expect(!registry.startsChord(Self.prefix), "an unbound action cannot run")
    }

    @Test func aNumberedFamilyAsAChordTakesEveryDigit() throws {
        let registry = Self.registry()
        registry.setChordOverride(ShortcutChord(Self.prefix, Shortcut("1", modifiers: [])), for: "fam")
        let resolved = try #require(registry.resolveChord(after: Self.prefix, Shortcut("7", modifiers: [])))
        #expect(resolved.id == "fam" && resolved.argument == "7")
        #expect(registry.shortcutDisplay(for: "fam") == "⌃B 1…9")
    }

    @Test func aMovedNumberedFamilyStaysAFamily() throws {
        let registry = Self.registry()
        registry.setShortcutOverride(Shortcut("1", modifiers: [.command, .option]), for: "fam")
        let resolved = try #require(registry.keyWinner(Shortcut("4", modifiers: [.command, .option])))
        #expect(resolved.command == "fam" && resolved.argument == "4")
        #expect(registry.keyWinner(Shortcut("4")) == nil)
        #expect(registry.shortcutDisplay(for: "fam") == "⌥⌘1…9")
    }

    @Test func aSingleKeyOverrideOrAResetEndsTheChord() {
        let registry = Self.registry()
        let chord = ShortcutChord(Self.prefix, Shortcut("c", modifiers: []))
        registry.setChordOverride(chord, for: "newTab")
        registry.setShortcutOverride(Shortcut("k"), for: "newTab")
        #expect(registry.effectiveChord(for: "newTab") == nil)
        #expect(registry.effectiveShortcut(for: "newTab") == Shortcut("k"))

        registry.setChordOverride(chord, for: "newTab")
        registry.removeShortcutOverride(for: "newTab")
        #expect(registry.effectiveChord(for: "newTab") == nil)
        #expect(registry.effectiveShortcut(for: "newTab") == Shortcut("t"))
        #expect(!registry.startsChord(Self.prefix))
    }
}
