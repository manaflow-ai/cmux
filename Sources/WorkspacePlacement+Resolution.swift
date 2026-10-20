import CmuxSettings
import Foundation

/// App-side placement resolution for new workspaces.
///
/// Fused-enum split status (TabManager decomposition): the legacy
/// `WorkspacePlacementSettings` namespace enum is gone — its storage key is
/// the CmuxSettings catalog's `app.newWorkspacePlacement` entry and the
/// app's `WorkspacePlacement` enum converged onto the catalog's
/// `WorkspacePlacement` value type. The pure resolvers below are **staged
/// for CmuxWorkspaces (Wave 4)**, where they move with the workspace
/// creation coordinator.
extension WorkspacePlacement {
    /// The placement to apply for a new workspace: an explicit call-site
    /// override wins, then iMessage mode pins `.top`, then the stored
    /// `app.newWorkspacePlacement` setting (default `.afterCurrent`).
    static func effectivePlacement(
        placementOverride: WorkspacePlacement?,
        settings: any SettingsReading,
        catalog: SettingCatalog
    ) -> WorkspacePlacement {
        if let placementOverride {
            return placementOverride
        }
        if settings.value(for: catalog.app.iMessageMode) {
            return .top
        }
        return settings.value(for: catalog.app.newWorkspacePlacement)
    }

    /// The insertion index for a new workspace under this placement, given
    /// the current selection and pinned-prefix shape of the tab list.
    /// Pure arithmetic; clamps every input into the valid range.
    func insertionIndex(
        selectedIndex: Int?,
        selectedIsPinned: Bool,
        pinnedCount: Int,
        totalCount: Int
    ) -> Int {
        let clampedTotalCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedTotalCount))

        switch self {
        case .top:
            // Keep pinned workspaces grouped at the top by inserting ahead of unpinned items.
            return clampedPinnedCount
        case .end:
            return clampedTotalCount
        case .afterCurrent:
            guard let selectedIndex, clampedTotalCount > 0 else {
                return clampedTotalCount
            }
            let clampedSelectedIndex = max(0, min(selectedIndex, clampedTotalCount - 1))
            if selectedIsPinned {
                return clampedPinnedCount
            }
            return min(clampedSelectedIndex + 1, clampedTotalCount)
        }
    }
}
