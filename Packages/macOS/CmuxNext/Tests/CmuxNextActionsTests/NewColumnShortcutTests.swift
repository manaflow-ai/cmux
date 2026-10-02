import Testing
@testable import CmuxNextActions

/// New Column is Ctrl-Cmd-D (user decision 2026-10-02,
/// plans/cmux-next/column-sizing.md), and no other action has it by default.
@Suite struct NewColumnShortcutTests {
    @Test func newColumnIsControlCommandDAndUnshared() throws {
        let chord = Shortcut("d", modifiers: [.control, .command])
        let newColumn = try #require(ActionCatalog.all.first { $0.id == "newColumn" })
        #expect(newColumn.defaultShortcut == chord)
        #expect(ActionCatalog.all.filter { $0.defaultShortcut == chord }.map(\.id) == ["newColumn"])
    }
}
