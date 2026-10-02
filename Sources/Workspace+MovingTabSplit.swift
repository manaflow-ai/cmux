import AppKit
import Bonsplit

extension Workspace {
    enum MovingTabSplitFocusIntent {
        case activateMovedTab
        case preserveCurrent
    }

    /// Moves an existing tab into a new split while making focus intent explicit.
    ///
    /// Bonsplit updates its focused pane synchronously but emits only `didSplitPane`
    /// for this operation. The scoped intent lets that delegate callback either
    /// commit the moved tab through Workspace's focus owner or restore the previous
    /// Bonsplit pane and any responder focus that panel actually owned.
    @discardableResult
    func splitPaneMovingTab(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        movingTab tabId: TabID,
        insertFirst: Bool,
        focusIntent: MovingTabSplitFocusIntent
    ) -> PaneID? {
        let previousIntent = activeMovingTabSplitFocusIntent
        let previousFocusedPanelId = focusedPanelId
        let previousOwnedFocusIntent = previousFocusedPanelId
            .flatMap { panels[$0] }
            .flatMap { ownedFocusIntent(for: $0) }
        activeMovingTabSplitFocusIntent = focusIntent
        defer { activeMovingTabSplitFocusIntent = previousIntent }

        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            movingTab: tabId,
            insertFirst: insertFirst
        ) else {
            return nil
        }

        if case .preserveCurrent = focusIntent,
           let previousFocusedPanelId,
           let previousPaneId = self.paneId(forPanelId: previousFocusedPanelId),
           let previousTabId = surfaceIdFromPanelId(previousFocusedPanelId) {
            if bonsplitController.selectedTab(inPane: previousPaneId)?.id != previousTabId {
                bonsplitController.selectTab(previousTabId)
            }
            if bonsplitController.focusedPaneId != previousPaneId {
                bonsplitController.focusPane(previousPaneId)
            }
            if let previousOwnedFocusIntent {
                focusPanel(
                    previousFocusedPanelId,
                    focusIntent: previousOwnedFocusIntent
                )
            }
        }

        return newPaneId
    }

    var preservesFocusDuringMovingTabSplit: Bool {
        if case .preserveCurrent? = activeMovingTabSplitFocusIntent {
            return true
        }
        return false
    }

    /// Commits the moved tab while protecting the terminal that owns AppKit focus
    /// from the responder churn caused by the following SwiftUI reparent pass.
    func activateMovedTabAfterSplit(_ tabId: TabID, inPane paneId: PaneID) {
        let previousHostedView = terminalHostedViewOwningFirstResponder()
        let terminalFocusPanelId = panelIdFromSurfaceId(tabId).flatMap { panelId in
            terminalPanel(for: panelId) == nil ? nil : panelId
        }

        suppressReparentFocusUntilLayoutFollowUp(
            previousHostedView,
            reason: "workspace.movingTabSplitReparent",
            terminalFocusPanelId: terminalFocusPanelId
        )
        applyTabSelection(
            tabId: tabId,
            inPane: paneId,
            previousTerminalHostedView: previousHostedView
        )
    }

    private func ownedFocusIntent(for panel: any Panel) -> PanelFocusIntent? {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else { return nil }
        return panel.ownedFocusIntent(for: firstResponder, in: window)
    }

    private func terminalHostedViewOwningFirstResponder() -> GhosttySurfaceScrollView? {
        guard let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder,
              let panelId = responder.cmuxTerminalFocusOwningGhosttyView()?.terminalSurface?.id else {
            return nil
        }
        return terminalPanel(for: panelId)?.hostedView
    }
}
