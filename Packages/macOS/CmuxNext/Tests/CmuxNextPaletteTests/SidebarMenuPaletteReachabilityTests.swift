import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Sidebar rows keep the long tail searchable after the pointer menu trim. Querying each action
/// ID exercises the same palette search path a person uses, rather than only checking descriptor
/// metadata.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct SidebarMenuPaletteReachabilityTests {
    private static let trimmedActions: [ActionID] = [
        "workspace.setTheme", "workspace.setTint", "workspace.removeAllColors",
        // Sidebar Density: Compact and Comfortable were never palette rows (Density: Compact is
        // the palette's one "compact" row); the sidebar background menu keeps all three.
        "sidebar.density.expanded", "workspace.copyPath", "palette.copyWorkspaceID",
        "palette.copyWorkspaceLink", "palette.copyWorkspaceIDAndRef", "copyWorkspaceSSHError",
        "agentChat.copyIdentifier", "workspace.showResources", "revealWorkspaceInFinder",
        "palette.openWorkspacePullRequests", "workspace.setRemoteLocalhost",
    ]

    @Test func everyTrimmedSidebarActionResolvesFromAPaletteSearch() async throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        for id in Self.trimmedActions { registry.bind(id, invoke: { _ in }) }
        let palette = PaletteController(registry: registry, frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(.commands)
        await palette.model.settle()

        for id in Self.trimmedActions {
            palette.model.send(.setQuery(id.rawValue))
            await palette.model.settle()
            #expect(palette.model.rows.contains { $0.item.actionID == id }, "palette search did not resolve \(id)")
        }
    }
}
