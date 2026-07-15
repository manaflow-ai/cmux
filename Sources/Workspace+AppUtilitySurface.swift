import Bonsplit
import CmuxCanvas
import CmuxWorkspaces
import Foundation

extension Workspace {
    func openMobilePairingSurface(inPane paneId: PaneID) {
        _ = openOrFocusAppUtilityPane(fromPane: paneId, kind: .mobilePairing, focus: true)
    }

    @discardableResult
    func openOrFocusAppUtilityPane(
        fromPane sourcePaneId: PaneID,
        kind: AppUtilityPanelKind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil,
        focus: Bool = true
    ) -> AppUtilityPanel? {
        // A remote tmux mirror is a 1:1 view of the remote layout. App utility
        // panes are local-only, and asking Bonsplit to split would route the
        // delegate callback to `tmux split-window` before vetoing the local pane.
        guard !isRemoteTmuxMirror else { return nil }

        for (existingId, panel) in panels {
            guard let utilityPanel = panel as? AppUtilityPanel,
                  utilityPanel.kind == kind else {
                continue
            }
            utilityPanel.requestSettingsNavigation(settingsNavigationTarget)
            if layoutMode == .canvas {
                placeAppUtilityPaneInCanvas(
                    existingId,
                    anchorPanelId: focusedPanelId,
                    focus: focus
                )
            } else if focus {
                clearSplitZoom()
                focusPanel(existingId)
            }
            return utilityPanel
        }
        return splitPaneWithAppUtility(
            targetPane: sourcePaneId,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget,
            focus: focus
        )
    }

    @discardableResult
    private func splitPaneWithAppUtility(
        targetPane paneId: PaneID,
        kind: AppUtilityPanelKind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil,
        focus: Bool
    ) -> AppUtilityPanel? {
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView
        let canvasPreferredSize = previousFocusedPanelId
            .flatMap { canvasModel.frame(of: $0) }

        let utilityPanel = AppUtilityPanel(
            workspaceId: id,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget
        )
        panels[utilityPanel.id] = utilityPanel
        panelTitles[utilityPanel.id] = utilityPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: utilityPanel.displayTitle,
            icon: utilityPanel.displayIcon,
            kind: SurfaceKind.appUtility.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: utilityPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: .horizontal,
            withTab: newTab,
            insertFirst: false
        ) else {
            panels.removeValue(forKey: utilityPanel.id)
            panelTitles.removeValue(forKey: utilityPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        if layoutMode == .canvas {
            if focus {
                suppressReparentFocusUntilLayoutFollowUp(
                    previousHostedView,
                    reason: "workspace.appUtilitySplitReparent"
                )
            }
            placeAppUtilityPaneInCanvas(
                utilityPanel.id,
                anchorPanelId: previousFocusedPanelId,
                preferredSize: canvasPreferredSize,
                focus: focus
            )
            if !focus {
                preserveFocusAfterNonFocusSplit(
                    preferredPanelId: previousFocusedPanelId,
                    splitPanelId: utilityPanel.id,
                    previousHostedView: previousHostedView
                )
            }
        } else if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.appUtilitySplitReparent"
            )
            focusPanel(utilityPanel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: utilityPanel.id,
                previousHostedView: previousHostedView
            )
        }
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: paneId,
            orientation: .horizontal,
            surfaceId: utilityPanel.id,
            kind: SurfaceKind.appUtility.rawValue,
            origin: "app_utility_split",
            focused: focus
        )

        return utilityPanel
    }

    private func placeAppUtilityPaneInCanvas(
        _ panelId: UUID,
        anchorPanelId: UUID?,
        preferredSize: CGRect? = nil,
        focus: Bool
    ) {
        guard layoutMode == .canvas else { return }
        canvasModel.syncPanes(
            panelIds: orderedPanelIds,
            focusedPanelId: anchorPanelId,
            preferredDirection: .right,
            preferredNewPaneSize: preferredSize.map {
                CanvasSize(width: Double($0.width), height: Double($0.height))
            }
        )
        if focus {
            focusPanel(panelId)
        }
        canvasModel.viewport?.modelDidChangeExternally(animated: false)
        if focus {
            canvasModel.viewport?.revealPane(panelId, animated: true)
        }
    }
}
