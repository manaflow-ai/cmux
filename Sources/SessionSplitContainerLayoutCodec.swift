import Bonsplit
import Foundation

/// Shared layout codec for workspace panes and Docks. Panel construction remains with the
/// owning container because workspaces support more panel kinds and remote transports, while
/// Docks intentionally support terminal and browser panes only.
@MainActor
struct SessionSplitContainerLayoutCodec {
    let controller: BonsplitController

    struct RestoreLeaf {
        let paneId: PaneID
        let snapshot: SessionPaneLayoutSnapshot
    }

    struct RestoreScaffold {
        let leaves: [RestoreLeaf]
        let placeholderTabIds: Set<TabID>
    }

    func snapshot(panelIdForTabId: (TabID) -> UUID?) -> SessionWorkspaceLayoutSnapshot {
        snapshot(
            node: controller.treeSnapshot(),
            panelIdForTabId: panelIdForTabId
        )
    }

    func pruned(
        _ node: SessionWorkspaceLayoutSnapshot,
        keeping panelIdsToKeep: Set<UUID>
    ) -> SessionWorkspaceLayoutSnapshot? {
        switch node {
        case .pane(let pane):
            let panelIds = pane.panelIds.filter { panelIdsToKeep.contains($0) }
            guard !panelIds.isEmpty else { return nil }
            return .pane(SessionPaneLayoutSnapshot(
                panelIds: panelIds,
                selectedPanelId: pane.selectedPanelId.flatMap {
                    panelIdsToKeep.contains($0) ? $0 : nil
                } ?? panelIds.first,
                isFullWidthTabMode: pane.isFullWidthTabMode
            ))
        case .split(let split):
            let first = pruned(split.first, keeping: panelIdsToKeep)
            let second = pruned(split.second, keeping: panelIdsToKeep)
            switch (first, second) {
            case (.some(let first), .some(let second)):
                return .split(SessionSplitLayoutSnapshot(
                    orientation: split.orientation,
                    dividerPosition: split.dividerPosition,
                    first: first,
                    second: second
                ))
            case (.some(let first), .none):
                return first
            case (.none, .some(let second)):
                return second
            case (.none, .none):
                return nil
            }
        }
    }

    /// Builds only the pane tree. Placeholder tabs make Bonsplit accept nested splits without
    /// spawning real terminal processes; callers replace them with restored panels immediately.
    func restoreScaffold(_ layout: SessionWorkspaceLayoutSnapshot) -> RestoreScaffold {
        guard let rootPaneId = controller.allPaneIds.first else {
            return RestoreScaffold(leaves: [], placeholderTabIds: [])
        }
        var leaves: [RestoreLeaf] = []
        var placeholders: Set<TabID> = []
        restoreNode(
            layout,
            inPane: rootPaneId,
            leaves: &leaves,
            placeholders: &placeholders
        )
        return RestoreScaffold(leaves: leaves, placeholderTabIds: placeholders)
    }

    func applyDividerPositions(
        snapshotNode: SessionWorkspaceLayoutSnapshot,
        liveNode: ExternalTreeNode
    ) {
        switch (snapshotNode, liveNode) {
        case (.split(let snapshotSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = controller.setDividerPosition(
                    CGFloat(snapshotSplit.dividerPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            applyDividerPositions(
                snapshotNode: snapshotSplit.first,
                liveNode: liveSplit.first
            )
            applyDividerPositions(
                snapshotNode: snapshotSplit.second,
                liveNode: liveSplit.second
            )
        default:
            return
        }
    }

    private func snapshot(
        node: ExternalTreeNode,
        panelIdForTabId: (TabID) -> UUID?
    ) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .pane(let pane):
            let tabs = pane.tabs.compactMap { tab -> (TabID, UUID)? in
                guard let tabUUID = UUID(uuidString: tab.id) else { return nil }
                let tabId = TabID(uuid: tabUUID)
                guard let panelId = panelIdForTabId(tabId) else { return nil }
                return (tabId, panelId)
            }
            let selectedPanelId = pane.selectedTabId.flatMap { UUID(uuidString: $0) }.flatMap {
                panelIdForTabId(TabID(uuid: $0))
            }
            return .pane(SessionPaneLayoutSnapshot(
                panelIds: tabs.map { $0.1 },
                selectedPanelId: selectedPanelId,
                isFullWidthTabMode: UUID(uuidString: pane.id).map {
                    controller.isFullWidthTabMode(inPane: PaneID(id: $0))
                }
            ))
        case .split(let split):
            return .split(SessionSplitLayoutSnapshot(
                orientation: split.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                dividerPosition: split.dividerPosition,
                first: snapshot(node: split.first, panelIdForTabId: panelIdForTabId),
                second: snapshot(node: split.second, panelIdForTabId: panelIdForTabId)
            ))
        }
    }

    private func restoreNode(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane paneId: PaneID,
        leaves: inout [RestoreLeaf],
        placeholders: inout Set<TabID>
    ) {
        switch node {
        case .pane(let pane):
            leaves.append(RestoreLeaf(paneId: paneId, snapshot: pane))
        case .split(let split):
            let sourcePlaceholder = ensurePlaceholder(
                inPane: paneId,
                placeholders: &placeholders
            )
            guard sourcePlaceholder != nil else {
                leaves.append(RestoreLeaf(
                    paneId: paneId,
                    snapshot: SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
                ))
                return
            }
            let newPlaceholder = Bonsplit.Tab(title: "", kind: "restoring")
            placeholders.insert(newPlaceholder.id)
            guard let secondPaneId = controller.splitPane(
                paneId,
                orientation: split.orientation.splitOrientation,
                withTab: newPlaceholder,
                insertFirst: false
            ) else {
                placeholders.remove(newPlaceholder.id)
                leaves.append(RestoreLeaf(paneId: paneId, snapshot: split.first.paneFallback))
                return
            }
            restoreNode(
                split.first,
                inPane: paneId,
                leaves: &leaves,
                placeholders: &placeholders
            )
            restoreNode(
                split.second,
                inPane: secondPaneId,
                leaves: &leaves,
                placeholders: &placeholders
            )
        }
    }

    private func ensurePlaceholder(
        inPane paneId: PaneID,
        placeholders: inout Set<TabID>
    ) -> TabID? {
        if let existing = controller.tabs(inPane: paneId).first?.id { return existing }
        let tabId = controller.createTab(title: "", kind: "restoring", inPane: paneId)
        if let tabId { placeholders.insert(tabId) }
        return tabId
    }
}

private extension SessionWorkspaceLayoutSnapshot {
    var paneFallback: SessionPaneLayoutSnapshot {
        switch self {
        case .pane(let pane): return pane
        case .split: return SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        }
    }
}
