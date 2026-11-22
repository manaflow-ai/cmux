import Testing
@testable import CmuxNextActions

/// Ctrl-` opens a new terminal tab (Lawrence call 2026-10-06, section E; the
/// New Tab page lists Terminal as ⌃`), and no other action has it by default.
@Suite struct NewTerminalShortcutTests {
    @Test func newTerminalTabIsControlBacktickAndUnshared() throws {
        let chord = Shortcut("`", modifiers: [.control])
        let newTerminal = try #require(ActionCatalog.all.first { $0.id == "newSurface" })
        #expect(newTerminal.defaultShortcut == chord)
        #expect(ActionCatalog.all.filter { $0.defaultShortcut == chord }.map(\.id) == ["newSurface"])
    }
}
