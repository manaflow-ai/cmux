import Bonsplit
public import Foundation

/// Derives the close targets for a workspace's focused pane: the plan for
/// "Close Other Tabs in Focused Pane", the panel the Close shortcut should
/// target, whether the Close shortcut should close the whole workspace on its
/// last surface, and whether closing the workspace needs confirmation.
///
/// These derivations are lifted one-for-one from the legacy `TabManager`
/// bodies (`closeOtherTabsInFocusedPanePlan`, `shortcutCloseTargetPanelId`,
/// `shouldCloseWorkspaceOnLastSurfaceShortcut`, `workspaceNeedsConfirmClose`).
/// The planner is pure derivation over ``FocusedPaneCloseTargetHosting`` and
/// never holds the app-target `Workspace`; the close mutation
/// (`markCloseHistoryEligible` / `closePanel`), the `NSAlert` confirmation, and
/// the settings read stay app-side in `TabManager`.
@MainActor
public struct FocusedPaneCloseTargetPlanner {
    private let host: any FocusedPaneCloseTargetHosting

    /// Creates a planner over the workspace-side host.
    public init(host: any FocusedPaneCloseTargetHosting) {
        self.host = host
    }

    /// The unpinned panels in the focused pane other than its selected tab,
    /// with their display titles, or `nil` when there is nothing to close.
    /// Lifted from `TabManager.closeOtherTabsInFocusedPanePlan` (the
    /// `selectedWorkspace` resolution stays app-side).
    public func closeOtherTabsPlan() -> CloseOtherTabsInFocusedPanePlan? {
        guard let paneId = host.focusedBonsplitPaneId ?? host.allBonsplitPaneIds.first else {
            return nil
        }

        let tabsInPane = host.tabs(inPane: paneId)
        guard !tabsInPane.isEmpty else { return nil }
        guard let selectedTabId = host.selectedTab(inPane: paneId)?.id ?? tabsInPane.first?.id else {
            return nil
        }

        var targetPanelIds: [UUID] = []
        var targetTitles: [String] = []
        for tab in tabsInPane where tab.id != selectedTabId {
            guard let panelId = host.panelId(forSurfaceId: tab.id) else { continue }
            if host.isPanelPinned(panelId) {
                continue
            }
            targetPanelIds.append(panelId)
            targetTitles.append(host.panelDisplayTitle(panelId: panelId))
        }

        guard !targetPanelIds.isEmpty else { return nil }
        return CloseOtherTabsInFocusedPanePlan(
            panelIds: targetPanelIds,
            titles: targetTitles
        )
    }

    /// The panel id the Close shortcut should target: the focused panel, else
    /// the sole panel, else the selected tab of the focused (or first) pane.
    /// Lifted from `TabManager.shortcutCloseTargetPanelId(in:)`.
    public func shortcutCloseTargetPanelId() -> UUID? {
        if let focusedPanelId = host.focusedPanelId,
           host.hasPanel(focusedPanelId) {
            return focusedPanelId
        }

        if host.panelCount == 1 {
            return host.firstPanelId
        }

        let candidatePane = host.focusedBonsplitPaneId ?? host.allBonsplitPaneIds.first
        if let candidatePane,
           let selectedTabId = host.selectedTab(inPane: candidatePane)?.id
                ?? host.tabs(inPane: candidatePane).first?.id,
           let panelId = host.panelId(forSurfaceId: selectedTabId),
           host.hasPanel(panelId) {
            return panelId
        }

        return nil
    }

    /// Whether the Close shortcut on the workspace's last surface should close
    /// the whole workspace. Lifted from
    /// `TabManager.shouldCloseWorkspaceOnLastSurfaceShortcut`; the
    /// `keepWorkspaceOpenWhenClosingLastSurface` setting is read app-side and
    /// passed in.
    public func shouldCloseWorkspaceOnLastSurfaceShortcut(
        panelId: UUID,
        keepWorkspaceOpenWhenClosingLastSurface: Bool
    ) -> Bool {
        // Stored under the legacy closeWorkspaceOnLastSurfaceShortcut key:
        // true means the Close shortcut closes the workspace on its last surface.
        keepWorkspaceOpenWhenClosingLastSurface &&
            host.panelCount <= 1 &&
            host.hasPanel(panelId)
    }

    /// Whether closing the workspace needs confirmation, honoring the DEBUG UI
    /// test override. Lifted from `TabManager.workspaceNeedsConfirmClose`.
    public func workspaceNeedsConfirmClose() -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] == "1" {
            return true
        }
#endif
        return host.needsConfirmClose()
    }
}
