import AppKit
import CmuxNextActions
import Testing

/// Replacing a key that is one of an action's several keys (`{"any": [...]}`,
/// https://github.com/manaflow-ai/cmux/issues/25564) takes that key alone from it.
@MainActor @Suite struct ShortcutRecorderAlternatesTests {
    typealias Harness = ShortcutRecorderReturnKeyTests.Harness

    /// `count` Ctrl-Opt-Cmd letters that no entry of the harness's binding table has, so recording one of them
    /// asks about no other action. Hard-coded letters went stale as catalog actions took them by default:
    /// Ctrl-Opt-Cmd-U became Show Context Usage's key (6092e29e, 2026-11-19), so the recorder asked about it and
    /// saving took the key from it, a second change the test did not expect.
    static func freeKeys(_ count: Int, in harness: Harness) throws -> [Shortcut] {
        let bound = Set(RegistryKeyBindings(harness.registry).table.entries.flatMap(\.keys))
        let free = "abcdefghijklmnopqrstuvwxyz".map { Shortcut(String($0), modifiers: [.control, .option, .command]) }
            .filter { !bound.contains($0) && SystemReservedShortcuts.shared.table[$0] == nil }
        try #require(free.count >= count, "only \(free.count) Ctrl-Opt-Cmd letters are free")
        return Array(free.prefix(count))
    }

    @Test func recordingAPrimaryKeyKeepsItsOtherBindings() throws {
        let harness = Harness()
        let keys = try Self.freeKeys(3, in: harness)
        let primary = keys[0]
        let alternate = [keys[1]]
        let chord = [Shortcut("b", modifiers: [.control]), Shortcut("n", modifiers: [])]
        let replacement = keys[2]
        harness.registry.setConfiguredShortcuts([[primary], alternate, chord], for: "about")
        #expect(harness.recorder.begin("about"))
        harness.recorder.handle(replacement, keyCode: 34)
        if harness.state?.pending != nil { harness.recorder.choose(.save) }
        let expected = [[replacement], alternate, chord]
        #expect(harness.registry.configuredShortcuts(for: "about") == expected)
        #expect(harness.editor.saved.last == [ShortcutChange("about", keys: expected)])
    }

    @Test func removingThePrimaryKeyKeepsItsOtherBindings() throws {
        let harness = Harness()
        let keys = try Self.freeKeys(2, in: harness)
        let primary = [keys[0]]
        let alternate = [keys[1]]
        harness.registry.setConfiguredShortcuts([primary, alternate], for: "about")
        #expect(harness.recorder.begin("about"))
        harness.recorder.choose(.remove)
        #expect(harness.registry.configuredShortcuts(for: "about") == [alternate])
        #expect(harness.editor.saved.last == [ShortcutChange("about", keys: [alternate])])
    }

    @Test func recordingAnExistingAlternateDoesNotDuplicateIt() throws {
        let harness = Harness()
        let keys = try Self.freeKeys(2, in: harness)
        let primary = [keys[0]]
        let alternate = keys[1]
        harness.registry.setConfiguredShortcuts([primary, [alternate]], for: "about")
        #expect(harness.recorder.begin("about"))
        harness.recorder.handle(alternate, keyCode: 32)
        if harness.state?.pending != nil { harness.recorder.choose(.save) }
        #expect(harness.registry.configuredShortcuts(for: "about") == [[alternate]])
        #expect(harness.editor.saved.last == [ShortcutChange("about", keys: [[alternate]])])
    }

    @Test func replaceTakesOnlyTheSharedKeyFromTheOtherAction() throws {
        let harness = Harness()
        let ctrlTab = [Shortcut("\t", modifiers: [.control])], cmdBracket = Shortcut("]", modifiers: [.command])
        harness.registry.setConfiguredShortcuts([ctrlTab, [cmdBracket]], for: "nextSurface")
        #expect(harness.recorder.begin("about"))
        harness.recorder.handle(cmdBracket, keyCode: 30)
        let pending = try #require(harness.state?.pending, "recording ⌘] should ask about nextSurface")
        guard case .set(_, let owners, _, let canReplace) = pending else { Issue.record("\(pending)"); return }
        #expect(owners.contains("nextSurface") && canReplace)

        harness.recorder.choose(.replace)
        #expect(harness.registry.configuredShortcuts(for: "nextSurface") == [ctrlTab])
        #expect(harness.editor.saved.last?.contains(ShortcutChange("nextSurface", keys: [ctrlTab])) == true,
                "saved \(harness.editor.saved)")
    }
}
