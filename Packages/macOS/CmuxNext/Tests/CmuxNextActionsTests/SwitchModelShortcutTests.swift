import Testing
@testable import CmuxNextActions

/// Switch Model… is Ctrl-Cmd-M (Lawrence 2026-10-09: "after cmd ctrl m we need to be focused in
/// the 'type to search models' area"), an app action so the chord works wherever the agent pane's
/// keyboard is, and no other action has it by default.
@Suite struct SwitchModelShortcutTests {
    @Test func switchModelIsControlCommandMAndUnshared() throws {
        let chord = Shortcut("m", modifiers: [.control, .command])
        let switchModel = try #require(ActionCatalog.all.first { $0.id == "agentPane.switchModel" })
        #expect(switchModel.defaultShortcut == chord)
        #expect(switchModel.requires.contains(.agentPaneFocused))
        #expect(ActionCatalog.all.filter { $0.defaultShortcut == chord }.map(\.id) == ["agentPane.switchModel"])
    }
}
