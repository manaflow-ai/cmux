import Bonsplit
import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    struct SplitResizeTarget {
        let orientation: SplitOrientation
        let paneId: Int
        let totalCells: Int
    }

    static func makeController(appearance: BonsplitConfiguration.Appearance) -> BonsplitController {
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: false,
            allowCrossPaneTabMove: false,
            autoCloseEmptyPanes: false,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .end,
            tabBarVisibility: .always,
            appearance: appearance
        )
        return BonsplitController(configuration: config)
    }

    func configureBonsplitController() {
        bonsplitController.delegate = self
        bonsplitController.onExternalTabDrop = { _ in false }
    }

    func rebuildBonsplitTree() {
        isApplyingRemoteLayout = true
        defer { isApplyingRemoteLayout = false }
        resetToSingleEmptyPane()
        tabIdByPaneId.removeAll()
        paneIdByPaneId.removeAll()
        paneIdByBonsplitPane.removeAll()
        paneIdByTabId.removeAll()
        guard let rootPane = bonsplitController.allPaneIds.first else { return }
        build(layout, inPane: rootPane)
        refreshDividerPositions()
    }

    func resetToSingleEmptyPane() {
        while bonsplitController.allPaneIds.count > 1, let pane = bonsplitController.allPaneIds.last {
            _ = bonsplitController.closePane(pane)
        }
        guard let rootPane = bonsplitController.allPaneIds.first else { return }
        for tab in bonsplitController.tabs(inPane: rootPane) {
            _ = bonsplitController.closeTab(tab.id, inPane: rootPane)
        }
    }

    @discardableResult
    func build(_ node: RemoteTmuxLayoutNode, inPane pane: PaneID) -> PaneID? {
        switch node.content {
        case .pane(let paneId):
            guard panelsByPaneId[paneId] != nil else { return nil }
            guard let tabId = bonsplitController.createTab(
                title: title(forPane: paneId),
                icon: "terminal",
                kind: "terminal",
                inPane: pane
            ) else { return nil }
            tabIdByPaneId[paneId] = tabId
            paneIdByPaneId[paneId] = pane
            paneIdByBonsplitPane[pane] = paneId
            paneIdByTabId[tabId] = paneId
            return pane
        case .horizontal(let children):
            return build(children: children, orientation: .horizontal, inPane: pane)
        case .vertical(let children):
            return build(children: children, orientation: .vertical, inPane: pane)
        }
    }

    func build(children: [RemoteTmuxLayoutNode], orientation: SplitOrientation, inPane pane: PaneID) -> PaneID? {
        guard let first = children.first else { return nil }
        guard children.count > 1 else { return build(first, inPane: pane) }
        let rest = Array(children.dropFirst())
        let fraction = RemoteTmuxMirrorLayoutMath.dividerFraction(
            first: first,
            rest: rest,
            horizontal: orientation == .horizontal
        )
        guard let restPane = bonsplitController.splitPane(
            pane,
            orientation: orientation,
            withTab: nil,
            initialDividerPosition: fraction
        ) else { return build(first, inPane: pane) }
        _ = build(first, inPane: pane)
        _ = build(combined(children: rest, orientation: orientation), inPane: restPane)
        return pane
    }

    func refreshDividerPositions() {
        splitTargets.removeAll()
        lastDividerPositions.removeAll()
        applyDividerPositions(tmuxNode: layout, treeNode: bonsplitController.treeSnapshot())
    }

    func repushClientSizeForLastContentSize() {
        guard let lastContentSizePoints else { return }
        _ = updateClientSize(contentSizePoints: lastContentSizePoints)
    }

    func applyDividerPositions(tmuxNode: RemoteTmuxLayoutNode, treeNode: ExternalTreeNode) {
        guard case .split(let split) = treeNode else { return }
        let children: [RemoteTmuxLayoutNode]
        let orientation: SplitOrientation
        switch tmuxNode.content {
        case .pane:
            return
        case .horizontal(let value):
            children = value
            orientation = .horizontal
        case .vertical(let value):
            children = value
            orientation = .vertical
        }
        guard let first = children.first, children.count > 1,
              let splitId = UUID(uuidString: split.id) else { return }
        let rest = Array(children.dropFirst())
        let fraction = RemoteTmuxMirrorLayoutMath.dividerFraction(
            first: first,
            rest: rest,
            horizontal: orientation == .horizontal
        )
        _ = bonsplitController.setDividerPosition(fraction, forSplit: splitId, fromExternal: true)
        lastDividerPositions[splitId] = fraction
        splitTargets[splitId] = SplitResizeTarget(
            orientation: orientation,
            paneId: first.paneIDsInOrder.first ?? 0,
            totalCells: orientation == .horizontal ? tmuxNode.width : tmuxNode.height
        )
        applyDividerPositions(tmuxNode: first, treeNode: split.first)
        applyDividerPositions(tmuxNode: combined(children: rest, orientation: orientation), treeNode: split.second)
    }

    func applyTargetedStructureChange(from oldLayout: RemoteTmuxLayoutNode, to newLayout: RemoteTmuxLayoutNode) -> Bool {
        let oldIds = Set(oldLayout.paneIDsInOrder)
        let newIds = Set(newLayout.paneIDsInOrder)
        if newIds.count == oldIds.count + 1,
           let added = newIds.subtracting(oldIds).first,
           let expansion = leafExpansion(from: oldLayout, to: newLayout, addedPaneId: added) {
            return applyLeafExpansion(expansion)
        }
        if oldIds.count == newIds.count + 1,
           let removed = oldIds.subtracting(newIds).first {
            return applyLeafRemoval(removedPaneId: removed, desiredLayout: newLayout)
        }
        return false
    }

    func applyLeafExpansion(_ expansion: LeafExpansion) -> Bool {
        guard let targetPane = paneIdByPaneId[expansion.existingPaneId],
              panelsByPaneId[expansion.newPaneId] != nil else { return false }
        let tab = makeBonsplitTab(forPane: expansion.newPaneId)
        isApplyingRemoteLayout = true
        let newPane = bonsplitController.splitPane(
            targetPane,
            orientation: expansion.orientation,
            withTab: tab,
            insertFirst: expansion.insertFirst,
            initialDividerPosition: expansion.fraction
        )
        isApplyingRemoteLayout = false
        guard let newPane else { return false }
        tabIdByPaneId[expansion.newPaneId] = tab.id
        paneIdByPaneId[expansion.newPaneId] = newPane
        paneIdByBonsplitPane[newPane] = expansion.newPaneId
        paneIdByTabId[tab.id] = expansion.newPaneId
        return bonsplitTreeMatches(layout: layout)
    }

    func applyLeafRemoval(removedPaneId: Int, desiredLayout: RemoteTmuxLayoutNode) -> Bool {
        guard let pane = paneIdByPaneId[removedPaneId] else { return false }
        isApplyingRemoteLayout = true
        let closed = bonsplitController.closePane(pane)
        isApplyingRemoteLayout = false
        guard closed else { return false }
        tabIdByPaneId[removedPaneId] = nil
        paneIdByPaneId[removedPaneId] = nil
        paneIdByBonsplitPane[pane] = nil
        paneIdByTabId = paneIdByTabId.filter { $0.value != removedPaneId }
        return bonsplitTreeMatches(layout: desiredLayout)
    }

    struct LeafExpansion {
        let existingPaneId: Int
        let newPaneId: Int
        let orientation: SplitOrientation
        let insertFirst: Bool
        let fraction: CGFloat
    }

    func leafExpansion(
        from oldNode: RemoteTmuxLayoutNode,
        to newNode: RemoteTmuxLayoutNode,
        addedPaneId: Int
    ) -> LeafExpansion? {
        if case .pane(let existingPaneId) = oldNode.content,
           let split = twoLeafSplit(newNode),
           split.paneIds.contains(existingPaneId),
           split.paneIds.contains(addedPaneId) {
            return LeafExpansion(
                existingPaneId: existingPaneId,
                newPaneId: addedPaneId,
                orientation: split.orientation,
                insertFirst: split.paneIds.first == addedPaneId,
                fraction: split.fraction
            )
        }
        guard let oldChildren = splitChildren(oldNode),
              let newChildren = splitChildren(newNode),
              oldChildren.orientation == newChildren.orientation,
              oldChildren.children.count == newChildren.children.count else { return nil }
        for (oldChild, newChild) in zip(oldChildren.children, newChildren.children) {
            if let expansion = leafExpansion(from: oldChild, to: newChild, addedPaneId: addedPaneId) {
                return expansion
            }
        }
        return nil
    }

    func twoLeafSplit(_ node: RemoteTmuxLayoutNode) -> (
        orientation: SplitOrientation,
        paneIds: [Int],
        fraction: CGFloat
    )? {
        guard let split = splitChildren(node), split.children.count == 2 else { return nil }
        let paneIds = split.children.compactMap { child -> Int? in
            if case .pane(let id) = child.content { return id }
            return nil
        }
        guard paneIds.count == 2 else { return nil }
        return (
            split.orientation,
            paneIds,
            RemoteTmuxMirrorLayoutMath.dividerFraction(
                first: split.children[0],
                rest: [split.children[1]],
                horizontal: split.orientation == .horizontal
            )
        )
    }

    func splitChildren(_ node: RemoteTmuxLayoutNode) -> (orientation: SplitOrientation, children: [RemoteTmuxLayoutNode])? {
        switch node.content {
        case .pane:
            return nil
        case .horizontal(let children):
            return (.horizontal, children)
        case .vertical(let children):
            return (.vertical, children)
        }
    }

    func makeBonsplitTab(forPane paneId: Int) -> Bonsplit.Tab {
        Bonsplit.Tab(
            title: title(forPane: paneId),
            icon: "terminal",
            kind: "terminal"
        )
    }

    func bonsplitTreeMatches(layout desiredLayout: RemoteTmuxLayoutNode) -> Bool {
        bonsplitTreeMatches(layout: desiredLayout, treeNode: bonsplitController.treeSnapshot())
    }

    func bonsplitTreeMatches(layout desiredLayout: RemoteTmuxLayoutNode, treeNode: ExternalTreeNode) -> Bool {
        switch desiredLayout.content {
        case .pane(let tmuxPaneId):
            guard case .pane(let pane) = treeNode,
                  let uuid = UUID(uuidString: pane.id),
                  let tabId = tabIdByPaneId[tmuxPaneId] else { return false }
            let bonsplitPane = PaneID(id: uuid)
            return paneIdByBonsplitPane[bonsplitPane] == tmuxPaneId
                && pane.tabs.contains { $0.id == tabId.uuid.uuidString }
        case .horizontal(let children):
            return splitTreeMatches(children: children, orientation: .horizontal, treeNode: treeNode)
        case .vertical(let children):
            return splitTreeMatches(children: children, orientation: .vertical, treeNode: treeNode)
        }
    }

    func splitTreeMatches(
        children: [RemoteTmuxLayoutNode],
        orientation: SplitOrientation,
        treeNode: ExternalTreeNode
    ) -> Bool {
        guard children.count > 1,
              case .split(let split) = treeNode,
              split.orientation == (orientation == .horizontal ? "horizontal" : "vertical"),
              let first = children.first else { return false }
        return bonsplitTreeMatches(layout: first, treeNode: split.first)
            && bonsplitTreeMatches(
                layout: combined(children: Array(children.dropFirst()), orientation: orientation),
                treeNode: split.second
            )
    }

    func seedActivePaneIfNeeded() {
        let live = layout.paneIDsInOrder
        let seed = connection?.activePaneByWindow[windowId] ?? live.first
        if activePaneId.map({ live.contains($0) }) != true, let seed {
            setActivePane(seed, fromTmux: true)
        } else if let activePaneId {
            setActivePane(activePaneId, fromTmux: true)
        }
    }

    func refreshPaneTitles() {
        for paneId in layout.paneIDsInOrder { updatePaneTitle(paneId) }
    }

    func title(forPane paneId: Int) -> String {
        RemoteTmuxMirrorLayoutMath.paneTitle(
            command: connection?.paneForegroundStates[paneId]?.command,
            cwd: cwdByPaneId[paneId]
        ) ?? String(localized: "remoteTmux.tab.pane", defaultValue: "tmux pane")
    }

    func currentSplitGeometry(splitId: UUID) -> (position: CGFloat, orientation: SplitOrientation)? {
        findSplitGeometry(splitId: splitId, node: bonsplitController.treeSnapshot())
    }

    func findSplitGeometry(splitId: UUID, node: ExternalTreeNode) -> (position: CGFloat, orientation: SplitOrientation)? {
        switch node {
        case .pane:
            return nil
        case .split(let split):
            if split.id == splitId.uuidString {
                return (
                    CGFloat(split.dividerPosition),
                    split.orientation == "horizontal" ? .horizontal : .vertical
                )
            }
            return findSplitGeometry(splitId: splitId, node: split.first)
                ?? findSplitGeometry(splitId: splitId, node: split.second)
        }
    }

    func combined(children: [RemoteTmuxLayoutNode], orientation: SplitOrientation) -> RemoteTmuxLayoutNode {
        guard children.count > 1 else { return children[0] }
        let minX = children.map(\.x).min() ?? 0
        let minY = children.map(\.y).min() ?? 0
        let maxX = children.map { $0.x + $0.width }.max() ?? 0
        let maxY = children.map { $0.y + $0.height }.max() ?? 0
        return RemoteTmuxLayoutNode(
            width: maxX - minX,
            height: maxY - minY,
            x: minX,
            y: minY,
            content: orientation == .horizontal ? .horizontal(children) : .vertical(children)
        )
    }

}
