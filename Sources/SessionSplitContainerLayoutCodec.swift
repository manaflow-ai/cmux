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

    /// Creates one pane-tree placeholder without constructing a live panel.
    func createRestorePlaceholderSplit(
        inPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> (paneId: PaneID, tabId: TabID)? {
        let placeholder = Bonsplit.Tab(title: "", kind: "restoring")
        guard let newPaneId = controller.splitPane(
            paneId,
            orientation: orientation,
            withTab: placeholder,
            insertFirst: insertFirst
        ) else {
            return nil
        }
        return (
            paneId: newPaneId,
            tabId: placeholder.id
        )
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
    /// Rebuilds a saved pane tree around the panels that are already alive.
    /// This is used by closed-panel history: creating a terminal just to make
    /// Bonsplit accept a split would execute the wrong Cloud creation path.
    @discardableResult
    func restoreExistingLayout(
        _ layout: SessionWorkspaceLayoutSnapshot,
        panelIDMap: [UUID: UUID],
        tabIDForPanelID: (UUID) -> TabID?
    ) -> Bool {
        guard let root = controller.allPaneIds.first else { return false }
        let desiredPanelIDs = layout.allPanelIDs
        let desiredTabs = desiredPanelIDs.compactMap { panelIDMap[$0] ?? $0 }
            .compactMap(tabIDForPanelID)
        guard desiredTabs.count == desiredPanelIDs.count else { return false }
        let liveTabIDs = Set(controller.allPaneIds.flatMap { controller.tabs(inPane: $0).map(\.id) })
        guard liveTabIDs.isSubset(of: Set(desiredTabs)) else { return false }
        for pane in controller.allPaneIds where pane != root {
            for tab in controller.tabs(inPane: pane) {
                _ = controller.moveTab(tab.id, toPane: root)
            }
        }
        let scaffold = restoreScaffold(layout)
        for leaf in scaffold.leaves {
            let panelIDs = leaf.snapshot.panelIds.compactMap { panelIDMap[$0] ?? $0 }
            for (index, panelID) in panelIDs.enumerated() {
                guard let tabID = tabIDForPanelID(panelID) else { return false }
                _ = controller.moveTab(tabID, toPane: leaf.paneId, atIndex: index)
            }
            if let selected = leaf.snapshot.selectedPanelId.flatMap({ panelIDMap[$0] ?? $0 }),
               let tabID = tabIDForPanelID(selected) {
                controller.focusPane(leaf.paneId)
                controller.selectTab(tabID)
            }
            _ = controller.setFullWidthTabMode(leaf.snapshot.isFullWidthTabMode == true, inPane: leaf.paneId)
        }
        for tabID in scaffold.placeholderTabIds {
            _ = controller.closeTab(tabID)
        }
        applyDividerPositions(snapshotNode: layout, liveNode: controller.treeSnapshot())
        return true
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
            guard let placeholderSplit = createRestorePlaceholderSplit(
                inPane: paneId,
                orientation: split.orientation.splitOrientation,
                insertFirst: false
            ) else {
                leaves.append(RestoreLeaf(paneId: paneId, snapshot: split.first.paneFallback))
                return
            }
            placeholders.insert(placeholderSplit.tabId)
            restoreNode(
                split.first,
                inPane: paneId,
                leaves: &leaves,
                placeholders: &placeholders
            )
            restoreNode(
                split.second,
                inPane: placeholderSplit.paneId,
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
    var allPanelIDs: [UUID] {
        switch self {
        case .pane(let pane): return pane.panelIds
        case .split(let split): return split.first.allPanelIDs + split.second.allPanelIDs
        }
    }

    var paneFallback: SessionPaneLayoutSnapshot {
        switch self {
        case .pane(let pane): return pane
        case .split: return SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        }
    }
}
