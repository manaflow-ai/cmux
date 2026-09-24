public import Bonsplit
import CoreGraphics
public import Foundation

/// Encodes and restores the pane tree shared by workspaces and Docks.
///
/// Panel construction remains with the owning container. This service only
/// translates between Bonsplit's live tree and the Sendable session snapshot,
/// and restores already-created tabs without creating terminal processes.
@MainActor
public struct SessionSplitContainerLayoutCodec {
    /// One restored leaf and its pane-local panel ordering.
    public struct RestoreLeaf {
        /// The live Bonsplit leaf receiving the panels.
        public let paneId: PaneID
        /// Saved panel order, selection and tab presentation.
        public let snapshot: SessionPaneLayoutSnapshot

        /// Creates a restored leaf description.
        init(paneId: PaneID, snapshot: SessionPaneLayoutSnapshot) {
            self.paneId = paneId
            self.snapshot = snapshot
        }
    }

    /// The scaffold leaves and inert tabs created while rebuilding a tree.
    public struct RestoreScaffold {
        /// Leaves in the restored tree's spatial order.
        public let leaves: [RestoreLeaf]
        /// Inert tabs the owner closes after installing its panels.
        public let placeholderTabIds: Set<TabID>

        /// Creates a restore scaffold result.
        init(leaves: [RestoreLeaf], placeholderTabIds: Set<TabID>) {
            self.leaves = leaves
            self.placeholderTabIds = placeholderTabIds
        }
    }

    private let controller: BonsplitController

    /// Creates a codec for one live Bonsplit controller.
    public init(controller: BonsplitController) {
        self.controller = controller
    }

    /// Captures the live pane tree and maps each surface tab to its panel id.
    public func snapshot(panelIdForTabId: (TabID) -> UUID?) -> SessionWorkspaceLayoutSnapshot {
        snapshot(node: controller.treeSnapshot(), panelIdForTabId: panelIdForTabId)
    }

    /// Removes panel ids that are no longer restorable and collapses empty
    /// split branches while preserving the saved divider metadata.
    public func pruned(
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

    /// Builds only the pane tree with inert tabs, so restoring a Cloud panel
    /// never creates an unrelated terminal process.
    public func restoreScaffold(_ layout: SessionWorkspaceLayoutSnapshot) -> RestoreScaffold {
        guard let rootPaneId = controller.allPaneIds.first else {
            return RestoreScaffold(leaves: [], placeholderTabIds: [])
        }
        var leaves: [RestoreLeaf] = []
        var placeholders: Set<TabID> = []
        restoreNode(layout, inPane: rootPaneId, leaves: &leaves, placeholders: &placeholders)
        return RestoreScaffold(leaves: leaves, placeholderTabIds: placeholders)
    }

    /// Creates one inert split placeholder without constructing a live panel.
    public func createRestorePlaceholderSplit(
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
        return (paneId: newPaneId, tabId: placeholder.id)
    }

    /// Applies saved divider positions to a matching live pane tree.
    public func applyDividerPositions(
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
            applyDividerPositions(snapshotNode: snapshotSplit.first, liveNode: liveSplit.first)
            applyDividerPositions(snapshotNode: snapshotSplit.second, liveNode: liveSplit.second)
        default:
            return
        }
    }

    /// Rebuilds a saved pane tree around panels that are already alive.
    ///
    /// If a newer live tab is absent from the saved snapshot, this method
    /// returns before mutating Bonsplit. That fail-closed path preserves the
    /// complete current topology instead of sweeping unrelated tabs into the
    /// root or closing their panes.
    @discardableResult
    public func restoreExistingLayout(
        _ layout: SessionWorkspaceLayoutSnapshot,
        panelIDMap: [UUID: UUID],
        tabIDForPanelID: (UUID) -> TabID?
    ) -> Bool {
        guard let root = controller.allPaneIds.first else { return false }
        let desiredPanelIDs = layout.allPanelIDs
        let desiredTabs = desiredPanelIDs.map { panelIDMap[$0] ?? $0 }
            .compactMap(tabIDForPanelID)
        guard desiredTabs.count == desiredPanelIDs.count,
              Set(desiredTabs).count == desiredTabs.count else { return false }
        let liveTabIDs = Set(controller.allPaneIds.flatMap {
            controller.tabs(inPane: $0).map(\.id)
        })
        guard liveTabIDs.isSubset(of: Set(desiredTabs)) else {
            return false
        }
        for pane in controller.allPaneIds where pane != root {
            for tab in controller.tabs(inPane: pane) {
                _ = controller.moveTab(tab.id, toPane: root)
            }
        }
        let scaffold = restoreScaffold(layout)
        for leaf in scaffold.leaves {
            let panelIDs = leaf.snapshot.panelIds.map { panelIDMap[$0] ?? $0 }
            for (index, panelID) in panelIDs.enumerated() {
                guard let tabID = tabIDForPanelID(panelID) else { return false }
                _ = controller.moveTab(tabID, toPane: leaf.paneId, atIndex: index)
            }
            if let selected = leaf.snapshot.selectedPanelId.flatMap({ panelIDMap[$0] ?? $0 }),
               let tabID = tabIDForPanelID(selected) {
                controller.focusPane(leaf.paneId)
                controller.selectTab(tabID)
            }
            _ = controller.setFullWidthTabMode(
                leaf.snapshot.isFullWidthTabMode == true,
                inPane: leaf.paneId
            )
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
            let selectedPanelId = pane.selectedTabId
                .flatMap { UUID(uuidString: $0) }
                .flatMap { panelIdForTabId(TabID(uuid: $0)) }
            return .pane(SessionPaneLayoutSnapshot(
                panelIds: tabs.map(\.1),
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
            guard ensurePlaceholder(inPane: paneId, placeholders: &placeholders) != nil else {
                leaves.append(RestoreLeaf(
                    paneId: paneId,
                    snapshot: split.first.paneFallback
                ))
                return
            }
            guard let placeholderSplit = createRestorePlaceholderSplit(
                inPane: paneId,
                orientation: split.orientation.splitOrientation,
                insertFirst: false
            ) else {
                leaves.append(RestoreLeaf(
                    paneId: paneId,
                    snapshot: split.first.paneFallback
                ))
                return
            }
            placeholders.insert(placeholderSplit.tabId)
            restoreNode(split.first, inPane: paneId, leaves: &leaves, placeholders: &placeholders)
            restoreNode(
                split.second,
                inPane: placeholderSplit.paneId,
                leaves: &leaves,
                placeholders: &placeholders
            )
        }
    }

    private func ensurePlaceholder(inPane paneId: PaneID, placeholders: inout Set<TabID>) -> TabID? {
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
