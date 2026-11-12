import Bonsplit
import CmuxSurfaceCatalogModel
import CmuxWorkspaces
import Foundation
import GhosttyKit

extension Workspace {
    /// A one-tab edge drag leaves a placeholder behind. The moved surface owns
    /// its replacement's execution context, even though it is now in another pane.
    func repairDraggedTabPlaceholder(in originalPane: PaneID, movedTabPane: PaneID, orientation: SplitOrientation) {
        let controller = bonsplitController
        let originalTabs = controller.tabs(inPane: originalPane)
        if let tab = controller.selectedTab(inPane: movedTabPane),
           let panelID = panelIdFromSurfaceId(tab.id),
           let source = cloudTerminalSourcePlacement(forPanel: panelID) {
            let frames = controller.treeSnapshot().paneFrames(for: Set([
                originalPane.id.uuidString, movedTabPane.id.uuidString
            ]))
            guard let originalFrame = frames[originalPane.id.uuidString],
                  let movedFrame = frames[movedTabPane.id.uuidString] else { return }
            let direction: SurfaceSplitDirection = orientation == .horizontal
                ? (originalFrame.midX < movedFrame.midX ? .left : .right)
                : (originalFrame.midY < movedFrame.midY ? .up : .down)
            if let terminal = terminalPanel(for: panelID) { rememberTerminalConfigInheritanceSource(terminal) }
            _ = routeCloudPaneTerminalCreate(
                source: source, sourcePanelID: panelID,
                destination: .tab(workspaceID: id, paneID: originalPane.id.uuidString, index: nil),
                focus: false, splitDirection: direction
            )
            // Success has reserved a manual-mirror pane. Failure is presented on
            // the moved source, so closing the unowned placeholder rolls back the
            // empty split without ever starting a local shell.
            for tab in originalTabs where panelIdFromSurfaceId(tab.id) == nil {
                _ = controller.closeTab(tab.id)
            }
            return
        }
        repairLocalDraggedTabPlaceholder(in: originalPane, originalTabs: originalTabs)
    }

    /// Keeps the pre-Cloud placeholder repair behavior for genuinely local tabs.
    private func repairLocalDraggedTabPlaceholder(in originalPane: PaneID, originalTabs: [Bonsplit.Tab]) {
        let controller = bonsplitController
        let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
    #if DEBUG
        cmuxDebugLog(
            "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
            "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
        )
    #endif
        if let replacementTab = placeholderTabs.first {
            // Keep the existing placeholder tab identity and replace only the panel mapping.
            // This avoids an extra create+close tab churn that can transiently render an
            // empty pane during drag-to-split of a single-tab pane.
            let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

            let replacementPanel = TerminalPanel(
                workspaceId: id,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: inheritedConfig,
                portOrdinal: portOrdinal,
                additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
            )
            configureNewTerminalPanel(replacementPanel)
            panels[replacementPanel.id] = replacementPanel
            panelTitles[replacementPanel.id] = replacementPanel.displayTitle
            bindSurface(replacementTab.id, toPanelId: replacementPanel.id)

            bonsplitController.updateTab(
                replacementTab.id,
                title: replacementPanel.displayTitle,
                icon: .some(replacementPanel.displayIcon),
                iconImageData: .some(nil),
                kind: .some(SurfaceKind.terminal.rawValue),
                hasCustomTitle: false,
                isDirty: replacementPanel.isDirty,
                showsNotificationBadge: false,
                isLoading: false,
                isPinned: false
            )
            rememberTerminalConfigInheritanceSource(replacementPanel)
            publishCmuxSurfaceCreated(replacementPanel.id, paneId: originalPane, kind: "terminal", origin: "placeholder_repair", focused: false)

            for extraPlaceholder in placeholderTabs.dropFirst() {
                bonsplitController.closeTab(extraPlaceholder.id)
            }
        } else {
    #if DEBUG
            cmuxDebugLog(
                "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                "fallback=createTerminalAndDropPlaceholders"
            )
    #endif
            _ = newTerminalSurface(inPane: originalPane, focus: false)
            for tab in controller.tabs(inPane: originalPane) {
                if panelIdFromSurfaceId(tab.id) == nil {
                    bonsplitController.closeTab(tab.id)
                }
            }
        }
    }
}

private extension ExternalTreeNode {
    /// Finds only the requested panes in one traversal without merging child dictionaries.
    func paneFrames(for paneIDs: Set<String>) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        collectPaneFrames(for: paneIDs, into: &result)
        return result
    }

    /// Collects requested pane frames in place so each split node is visited once.
    private func collectPaneFrames(for paneIDs: Set<String>, into result: inout [String: CGRect]) {
        guard result.count < paneIDs.count else { return }
        switch self {
        case .pane(let pane):
            guard paneIDs.contains(pane.id) else { return }
            result[pane.id] = CGRect(x: pane.frame.x, y: pane.frame.y, width: pane.frame.width, height: pane.frame.height)
        case .split(let split):
            split.first.collectPaneFrames(for: paneIDs, into: &result)
            split.second.collectPaneFrames(for: paneIDs, into: &result)
        }
    }
}
