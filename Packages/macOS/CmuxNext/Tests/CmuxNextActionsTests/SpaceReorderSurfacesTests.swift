@testable import CmuxNextActions
import Testing

/// Reordering a space (Lawrence 2026-10-27: "moving it first, last or to an index") is one catalog
/// action per verb, each offered in the Cmd-Shift-P palette, as a `cmux space` CLI verb and as an
/// MCP tool, besides the drag in the space strip.
@MainActor @Suite struct SpaceReorderSurfacesTests {
    nonisolated static let verbs: [(ActionID, String)] = [
        ("space.moveToStart", "space move-to-start"),
        ("space.moveToEnd", "space move-to-end"),
        ("space.move", "space move"),
        ("space.moveLeft", "space move-left"),
        ("space.moveRight", "space move-right"),
    ]

    @Test(arguments: verbs)
    func verbIsInThePaletteTheCLIAndMCP(_ id: ActionID, _ cli: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is no catalog action")
        #expect(descriptor.cliName == cli)
        #expect(descriptor.targets == [.profile], "\(id) does not take a space")
        let plan = descriptor.surfacePlan
        #expect(plan.palette.isOffered, "\(id): not in the palette")
        #expect(plan.cli?.isOffered == true, "\(id): no CLI verb")
        #expect(plan.mcp?.isOffered == true, "\(id): no MCP tool")
    }

    /// Typing "first" or "last" in the palette finds the matching verb.
    @Test(arguments: [("space.moveToStart", "first"), ("space.moveToEnd", "last")] as [(ActionID, String)])
    func paletteFindsTheVerbByItsUsualWord(_ id: ActionID, _ word: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is no catalog action")
        #expect(descriptor.keywords.contains(word), "\(id) keywords: \(descriptor.keywords)")
    }
}
