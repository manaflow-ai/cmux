import AppKit
import CmuxNextActions
import Testing

/// Replacing a key that is one of an action's several keys (`{"any": [...]}`,
/// https://github.com/manaflow-ai/cmux/issues/25564) takes that key alone from it.
@MainActor @Suite struct ShortcutRecorderAlternatesTests {
    typealias Harness = ShortcutRecorderReturnKeyTests.Harness

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
