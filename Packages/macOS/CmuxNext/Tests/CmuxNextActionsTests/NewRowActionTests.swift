import CmuxNextActions
import Testing

/// New Row (plans/cmux-next/rows.md, Surfaces): Cmd-Ctrl-Shift-D, palette,
/// View menu, CLI `pane new-row`, MCP and the pane context menu after New
/// Column.
@MainActor
@Suite struct NewRowActionTests {
    @Test func newRowIsOfferedOnEverySurface() throws {
        let row = try #require(ActionCatalog.all.first { $0.id == "newRow" })
        #expect(row.title == "New Row")
        #expect(row.defaultShortcut == Shortcut("d", modifiers: [.control, .shift, .command]))
        #expect(row.cliName == "pane new-row")
        #expect(row.mainMenu == .view)
        #expect(row.surfacePlan.palette == .offered)
        #expect(row.surfacePlan.cli == .offered)
        #expect(row.surfacePlan.mcp == .offered)
        let menu = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .pane))
        let column = try #require(menu.firstIndex(of: "newColumn"))
        let newRow = try #require(menu.firstIndex(of: "newRow"))
        #expect(column < newRow)
    }
}
