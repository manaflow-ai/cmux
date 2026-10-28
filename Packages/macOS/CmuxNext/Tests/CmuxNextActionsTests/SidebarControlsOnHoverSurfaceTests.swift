@testable import CmuxNextActions
import Testing

/// Show Sidebar Controls Only on Hover's two commands (`sidebar.controlsOnHover.on` / `.off`) reach every surface the
/// user asked for (Lawrence 2026-10-27: Cmd+Shift+P, the CLI and MCP "for literally everything"):
/// the palette lists them, `cmux sidebar ...` runs them, and `cmux mcp serve` offers them as tools.
@MainActor
struct SidebarControlsOnHoverSurfaceTests {
    nonisolated static let commands: [(id: ActionID, cli: String)] = [
        ("sidebar.controlsOnHover.on", "sidebar hide-controls-until-hover"),
        ("sidebar.controlsOnHover.off", "sidebar show-controls-always"),
    ]

    @Test(arguments: commands.map(\.id))
    func theCommandIsInThePaletteTheCLIAndMCP(_ id: ActionID) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is in the catalog")
        let expectedCLI = Self.commands.first { $0.id == id }?.cli
        #expect(descriptor.surfaces.contains(.palette), "Cmd+Shift+P")
        #expect(descriptor.surfacePlan.decision(for: .palette)?.isOffered == true, "Cmd+Shift+P")
        #expect(descriptor.cliName == expectedCLI, "CLI name")
        #expect(descriptor.surfacePlan.decision(for: .cli)?.isOffered == true, "CLI")
        #expect(descriptor.surfacePlan.decision(for: .mcp)?.isOffered == true, "MCP")
    }
}
