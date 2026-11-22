import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// The compact workspace list is discoverable in the sidebar view menu as a checkable,
/// off-by-default toggle in every build (Leo 2026-10-21: "They're just toggles in the app store
/// area"); it writes `sidebar.workspacesAsTabs`. Density choices remain visible beside it.
@MainActor
@Suite(.serialized)
struct SidebarCompactListMenuTests {
    @Test func compactListIsASidebarViewActionInEveryBuild() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == "sidebar.compactList.toggle" })
        #expect(!descriptor.isDebugOnly)
        #expect(descriptor.surfacePlan.cli == .exempt(.guiOnly))
        #expect(descriptor.surfacePlan.contextMenus.contains { $0.context == .sidebarBackground && $0.folder == .options })
    }

    @Test func sidebarViewKeepsAllDensityChoicesAlongsideCompactList() {
        let ids = Set(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .sidebarBackground)).map(\.rawValue))
        #expect(ids.isSuperset(of: ["sidebar.compactList.toggle", "sidebar.density.compact", "sidebar.density.comfortable", "sidebar.density.expanded"]))
    }

    @Test func compactListToggleIsOffByDefault() {
        #expect(SidebarTunables.workspacesAsTabs.defaultValue == false)
        #expect(SidebarSectionsPreferences.defaults.workspacesAsTabs == false)
    }
}
