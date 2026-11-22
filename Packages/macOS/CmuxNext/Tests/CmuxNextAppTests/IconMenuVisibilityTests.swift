import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import Testing

/// cx-k9go: a workspace row's right-click menu offers Remove Icon only while
/// that workspace shows an icon; Set Icon… is always there. The app's own
/// bindings decide it from the daemon's workspace record, so the rule holds
/// for the row a person right-clicks, not the focused one. Windows are never
/// put on screen.
@MainActor @Suite struct IconMenuVisibilityTests {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            item.isSeparatorItem ? [] : [item.title] + (item.submenu.map(titles) ?? [])
        }
    }

    @Test func removeIconFollowsTheRightClickedWorkspacesIcon() {
        let services = WorkspacePinTilesTests.services(owner: nil)
        WorkspacePinTilesTests.tree(services, icons: [nil, "🚀", nil])
        func rows(_ index: Int) -> [String] {
            let target = ActionTargetRef(kind: .workspace, id: WorkspacePinTilesTests.id(index))
            return titles(services.registry.makeContextMenu(for: .workspaceRow, target: target))
        }
        #expect(rows(1).contains("Set Icon…"))
        #expect(!rows(1).contains("Remove Icon"), "\(rows(1))")
        #expect(rows(2).contains("Remove Icon"), "\(rows(2))")
    }
}
