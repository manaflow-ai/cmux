@testable import CmuxNextActions
import Testing

/// Lawrence 2026-10-20: New Tab After Current Tab, New Tab at Start and New Tab at End are in
/// Cmd-Shift-P, the CLI and MCP (one action each, like every other tab action).
@MainActor struct NewTabPositionActionsTests {
    @Test(arguments: [
        ("newTab.afterCurrent", "New Tab After Current Tab", "tab new-after-current"),
        ("newTab.atStart", "New Tab at Start", "tab new-at-start"),
        ("newTab.atEnd", "New Tab at End", "tab new-at-end"),
    ])
    func eachIsAPaletteRowAndACLIVerb(id: String, title: String, cli: String) throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: ActionID(rawValue: id)))
        #expect(descriptor.title == title)
        #expect(descriptor.surfaces.contains(.palette))
        #expect(descriptor.cliName == cli)
    }
}
