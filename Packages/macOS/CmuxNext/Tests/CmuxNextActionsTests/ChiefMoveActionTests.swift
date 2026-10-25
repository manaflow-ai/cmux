@testable import CmuxNextActions
import Testing

/// "Move Chief To…" (remote-groups-DESIGN.md slice 6) is a palette action; the CLI and MCP run the same
/// move as `cmux chief move --to` and the Chief's `move` tool, so the action has no CLI verb of its own.
@MainActor @Suite struct ChiefMoveActionTests {
    @Test func moveChiefIsAPaletteActionWithATarget() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "chief.moveTo" })
        #expect(action.surfacePlan.palette.isOffered)
        #expect(action.surfacePlan.cli == .exempt(.familyMember))
        #expect(action.isDestructive, "the registry asks before an automation run moves the Chief")
        #expect(action.arguments.contains { $0.name == "target" })
    }
}
