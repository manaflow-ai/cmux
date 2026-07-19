import CmuxRemoteSession
import Bonsplit
import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    var renderedLayout: RemoteTmuxLayoutNode { visibleLayout ?? layout }

    static func makeController(configuration: BonsplitConfiguration) -> BonsplitController {
        BonsplitController(
            configuration: configuration.remoteTmuxEmbedded
        )
    }

    func configureBonsplitController() {
        bonsplitController.delegate = self
        bonsplitController.tabShortcutHintsEnabled = false
        bonsplitController.onExternalTabDrop = { _ in false }
    }

    func reconcileBonsplitTree(
        from previousLayout: RemoteTmuxLayoutNode,
        to newLayout: RemoteTmuxLayoutNode
    ) {
        let treeReady = bonsplitTreeMatches(layout: previousLayout)
        if newLayout == previousLayout, treeReady {
            setNeedsSizingPass()
        } else if treeReady, Self.sameShapeAndPaneIds(previousLayout, newLayout) {
            setNeedsSizingPass()
        } else if treeReady, applyTargetedStructureChange(from: previousLayout, to: newLayout) {
            setNeedsSizingPassIgnoringInputs()
        } else {
            rebuildBonsplitTree()
        }
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
        build(renderedLayout, inPane: rootPane)
        setNeedsSizingPassIgnoringInputs()
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
        let fraction = nativeDividerFraction(
            first: first,
            rest: rest,
            orientation: orientation
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

    /// The plan-and-apply half of the sizing transaction. Called ONLY from
    /// ``performSizingPassNow()``, which owns visibility gating, coalescing, and
    /// the fixed-point settled check — nothing here needs to defend against
    /// re-entry or duplicate triggers, because triggers cannot reach this
    /// function directly. (Hidden tabs never get here: their portal hosts
    /// have no window clamping them, and imposing absolute extents into an
    /// unclamped host once inflated it without bound.)
    func imposeDividerPlan(retryImposedExtents: Bool) {
        let treeNode = bonsplitController.treeSnapshot()
        pruneDividerBaselines(to: treeNode)
        let splitTree = RemoteTmuxNativeSplitTree(layout: renderedLayout)
        if let metrics = nativeLayoutMetrics() {
            let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
            let plan = planner.plan(
                tree: RemoteTmuxNativeMeasuredSplitTree(
                    tree: splitTree,
                    metrics: metrics
                ),
                parentSize: containerSizePt
            )
            applyDividerPositions(
                plan: plan, treeNode: treeNode, retryImposedExtents: retryImposedExtents
            )
        } else {
            applyFallbackDividerPositions(tmuxTree: splitTree, treeNode: treeNode)
        }
    }

    /// Applies a computed divider plan (``RemoteTmuxNativeSplitLayoutPlanner``) to
    /// the bonsplit tree — position-by-position, so the plan's shape must
    /// match the snapshot it was computed against. A mismatch means the
    /// bonsplit tree drifted from the layout the plan was computed for;
    /// every divider below the mismatch keeps its stale fraction, so make
    /// it loud in DEBUG instead of silently misrendering.
    func applyDividerPositions(
        plan: RemoteTmuxNativeSplitLayoutPlanner.Plan,
        treeNode: ExternalTreeNode,
        retryImposedExtents: Bool
    ) {
        guard case .split(let split) = treeNode,
              case .split(
                  let orientation, let fraction, let firstExtent, let firstPlan, let secondPlan
              ) = plan
        else {
            if case .split = treeNode {
                #if DEBUG
                cmuxDebugLog("remote.divider.plan mismatch: plan leaf vs bonsplit split")
                #endif
            }
            return
        }
        guard split.orientation == orientation.treeName,
              let splitId = UUID(uuidString: split.id)
        else {
            #if DEBUG
            cmuxDebugLog(
                "remote.divider.plan mismatch: orientation \(split.orientation) vs \(orientation)"
            )
            #endif
            return
        }
        // Impose exact points when the plan has them; a normalized fraction
        // is kept only for the no-container fallback, because fractions pass
        // through drift deadbands that can eat several columns at terminal
        // container sizes.
        let continuesExistingExtent = firstExtent.flatMap { planned in
            split.imposedFirstExtent.map { abs(CGFloat($0) - planned) <= 0.01 }
        } == true
        let repeatsExistingExtent = retryImposedExtents && continuesExistingExtent
        if firstExtent != nil {
            let current = CGFloat(split.dividerPosition)
            if continuesExistingExtent || abs(current - fraction) <= 0.005 {
                lastDividerPositions[splitId] = current
            } else {
                // The actual minimum-clamped outcome is not known until
                // Bonsplit's deferred apply. Its geometry callback records
                // that value; if no callback arrives, the first drag event
                // seeds the baseline without folding in the imposed move.
                lastDividerPositions[splitId] = nil
            }
        }
        _ = bonsplitController.setImposedFirstExtent(
            firstExtent, forSplit: splitId, fromExternal: true
        )
        if repeatsExistingExtent {
            _ = bonsplitController.retryImposedFirstExtent(forSplit: splitId)
        }
        if firstExtent == nil {
            _ = bonsplitController.setDividerPosition(fraction, forSplit: splitId, fromExternal: true)
            lastDividerPositions[splitId] = fraction
        }
        // Exact impositions rebaseline from their post-layout outcome;
        // fraction fallback above is synchronous and already authoritative.
        applyDividerPositions(
            plan: firstPlan, treeNode: split.first, retryImposedExtents: retryImposedExtents
        )
        applyDividerPositions(
            plan: secondPlan, treeNode: split.second, retryImposedExtents: retryImposedExtents
        )
    }

    func applyFallbackDividerPositions(
        tmuxTree: RemoteTmuxNativeSplitTree,
        treeNode: ExternalTreeNode
    ) {
        guard case .split(let split) = treeNode,
              case .split(_, let orientation, let firstTree, let secondTree) = tmuxTree,
              split.orientation == orientation.treeName,
              let splitId = UUID(uuidString: split.id) else { return }
        let fraction = Self.dividerFraction(
            first: firstTree.layout,
            rest: [secondTree.layout],
            horizontal: orientation == .horizontal
        )
        _ = bonsplitController.setImposedFirstExtent(nil, forSplit: splitId, fromExternal: true)
        _ = bonsplitController.setDividerPosition(fraction, forSplit: splitId, fromExternal: true)
        lastDividerPositions[splitId] = fraction
        applyFallbackDividerPositions(tmuxTree: firstTree, treeNode: split.first)
        applyFallbackDividerPositions(tmuxTree: secondTree, treeNode: split.second)
    }

    func applyTargetedStructureChange(from oldLayout: RemoteTmuxLayoutNode, to newLayout: RemoteTmuxLayoutNode) -> Bool {
        let oldIds = Set(oldLayout.paneIDsInOrder)
        let newIds = Set(newLayout.paneIDsInOrder)
        if newIds.count == oldIds.count + 1,
           let added = newIds.subtracting(oldIds).first,
           let expansion = leafExpansion(from: oldLayout, to: newLayout, addedPaneId: added) {
            return applyLeafExpansion(expansion, desiredLayout: newLayout)
        }
        if oldIds.count == newIds.count + 1,
           let removed = oldIds.subtracting(newIds).first {
            return applyLeafRemoval(removedPaneId: removed, desiredLayout: newLayout)
        }
        return false
    }

    func applyLeafExpansion(
        _ expansion: LeafExpansion,
        desiredLayout: RemoteTmuxLayoutNode
    ) -> Bool {
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
        return bonsplitTreeMatches(layout: desiredLayout)
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
            nativeDividerFraction(
                first: split.children[0],
                rest: [split.children[1]],
                orientation: split.orientation
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
              split.orientation == orientation.treeName,
              let first = children.first else { return false }
        return bonsplitTreeMatches(layout: first, treeNode: split.first)
            && bonsplitTreeMatches(
                layout: combined(children: Array(children.dropFirst()), orientation: orientation),
                treeNode: split.second
            )
    }

    func seedActivePaneIfNeeded() {
        let live = renderedLayout.paneIDsInOrder
        let seed = connection?.activePaneByWindow[windowId] ?? live.first
        if activePaneId.map({ live.contains($0) }) != true, let seed {
            setActivePane(seed, fromTmux: true)
        } else if let activePaneId {
            setActivePane(activePaneId, fromTmux: true)
        }
    }

    func refreshPaneTitles() {
        for paneId in renderedLayout.paneIDsInOrder { updatePaneTitle(paneId) }
    }

    func tmuxPaneId(forTab tabId: TabID) -> Int? { paneIdByTabId[tabId] }

    func isFocused(tabId: TabID) -> Bool {
        tmuxPaneId(forTab: tabId).map { $0 == activePaneId } ?? false
    }

    func updatePaneCwd(paneId: Int, path: String) {
        cwdByPaneId[paneId] = path
        updatePaneTitle(paneId)
    }

    func updatePaneTitle(_ paneId: Int) {
        guard let tabId = tabIdByPaneId[paneId] else { return }
        bonsplitController.updateTab(tabId, title: title(forPane: paneId))
    }

    func focusBonsplitPane(forTmuxPane paneId: Int) {
        // Idempotence guard: reconciles re-assert the active pane on every
        // %layout-change echo, and an unconditional focusPane would mutate
        // Bonsplit focus state (and fire didFocusPane) each time, stealing
        // first responder from whatever the user is typing in.
        guard let bonsplitPane = paneIdByPaneId[paneId],
              bonsplitController.focusedPaneId != bonsplitPane else { return }
        isApplyingTmuxFocus = true
        bonsplitController.focusPane(bonsplitPane)
        isApplyingTmuxFocus = false
    }

    func title(forPane paneId: Int) -> String {
        let index = paneIndexByPaneId[paneId] ?? 0
        return Self.windowPaneTitle(windowTitle, paneIndex: index)
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

extension RemoteTmuxWindowMirror: BonsplitDelegate {
    func splitTabBar(
        _ controller: BonsplitController,
        shouldCloseTab tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) -> Bool {
        guard !isApplyingRemoteLayout else { return true }
        if let tmuxPane = paneIdByTabId[tab.id] { onClosePaneRequest?(tmuxPane) }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        isApplyingRemoteLayout
    }

    func splitTabBar(
        _ controller: BonsplitController,
        shouldSplitPane pane: PaneID,
        orientation: SplitOrientation
    ) -> Bool {
        guard !isApplyingRemoteLayout else { return true }
        if let tmuxPane = paneIdByBonsplitPane[pane] {
            _ = requestSplit(fromPane: tmuxPane, vertical: orientation == .vertical)
        }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard !isApplyingRemoteLayout, !isApplyingTmuxFocus,
              let tmuxPane = paneIdByBonsplitPane[pane],
              activePaneId != tmuxPane else { return }
        focus(pane: tmuxPane)
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        guard !isApplyingRemoteLayout else { return }
        syncChangedDividerPositions()
    }
}
