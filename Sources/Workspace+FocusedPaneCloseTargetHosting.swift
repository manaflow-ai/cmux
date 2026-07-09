import Bonsplit
import CmuxPanes
import Foundation

/// `Workspace` is the live host for its ``FocusedPaneCloseTargetPlanner``. Every
/// member reads the authoritative `BonsplitController` split tree or the
/// workspace's panel bookkeeping, reproducing the reads the legacy `TabManager`
/// close-target bodies performed inline.
///
/// `panelId(forSurfaceId:)`, `focusedBonsplitPaneId`, and `selectedTab(inPane:)`
/// are shared witnesses with the ``SplitMoveReorderHosting`` conformance;
/// `allBonsplitPaneIds` and `tabs(inPane:)` are shared with
/// ``SurfaceLifecycleHosting``; `hasPanel(_:)` is shared with the
/// `BrowserOpenWorkspaceHandle` conformance; and `focusedPanelId`,
/// `isPanelPinned(_:)`, and `needsConfirmClose()` witness directly from their
/// existing `Workspace` members. The witnesses below are the only ones unique to
/// this seam. `panelDisplayTitle(panelId:)` keeps the localized
/// `CloseOtherTabsConfirmationPrompt.displayTitle` computation app-side.
extension Workspace: FocusedPaneCloseTargetHosting {
    var panelCount: Int { panels.count }

    var firstPanelId: UUID? { panels.keys.first }

    func panelDisplayTitle(panelId: UUID) -> String {
        CloseOtherTabsConfirmationPrompt.displayTitle(panelTitle(panelId: panelId))
    }
}
