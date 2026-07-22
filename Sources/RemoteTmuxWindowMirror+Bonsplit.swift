import AppKit
import Bonsplit
import CmuxRemoteSession
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
        // Resolve an in-flight divider send against the layout this plan is
        // built from. Only a layout that ASSIGNS the sent span ends the
        // round-trip window (the reply landed) — an unrelated layout change
        // replans from a tree that is still pre-drag for the held split, so
        // the hold survives and the held split's divider is skipped below.
        let heldSplitId = resolveDividerResizeHold(
            tmuxTree: splitTree, treeNode: treeNode
        )
        if let metrics = nativeLayoutMetrics() {
            let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
            // Plan against the exact-fit render size, not the whole region:
            // at the exact fit every split divides precisely its children's
            // ideals, so no pane absorbs the region's sub-cell remainder
            // along a split axis (the remainder sits outside the tree as
            // trailing margin — see renderFrameSize).
            //
            // INVARIANT plan(w) ≤ w: the parent the plan divides may never
            // exceed the banked region. A claimed≠layout disagreement (a
            // reconnect racing a resize can leave one permanently) makes the
            // assigned tree's exact size larger than the region; a plan
            // derived past the region demands geometry the container cannot
            // hold, the hosting window grows a point to satisfy it, the next
            // pass reads the growth back, and the window ratchets +1 per
            // pass to the display cap. Under disagreement the plan degrades
            // to the region — never past it — and the mismatch heals through
            // the claim/layout channel, not through window growth.
            let planParent = Self.regionBoundedPlanParent(
                renderFrame: renderFrameSize, region: containerSizePt
            )
            let plan = planner.plan(
                tree: RemoteTmuxNativeMeasuredSplitTree(
                    tree: splitTree,
                    metrics: metrics
                ),
                parentSize: planParent
            )
            let plannedOuterSizes = planner.outerSizes(of: plan)
            #if DEBUG
            // Log only a CHANGED plan: settled passes re-impose the same
            // outers every trigger, and repeating the line buries the
            // transitions the log exists to show.
            if plannedOuterSizes != lastPlannedOuterSizes {
                let planSummary = plannedOuterSizes
                    .sorted { $0.key < $1.key }
                    .map { "%\($0.key)=\(Int($0.value.width))x\(Int($0.value.height))" }
                    .joined(separator: " ")
                cmuxDebugLog(
                    "remote.divider.plan @\(windowId) parent=\(Int((planParent ?? .zero).width))x\(Int((planParent ?? .zero).height)) titleRow=\(Int(metrics.paneTitleRowHeight)) outers[\(planSummary)]"
                )
            }
            #endif
            lastPlannedOuterSizes = plannedOuterSizes
            applyDividerPositions(
                plan: plan, treeNode: treeNode, retryImposedExtents: retryImposedExtents,
                skippingSubtree: heldSplitId
            )
        } else {
            // No metrics means no point plan exists: the fraction fallback
            // below is not the plan the parity check should judge views
            // against, so a stale exact plan must not linger here.
            lastPlannedOuterSizes = [:]
            applyFallbackDividerPositions(
                tmuxTree: splitTree, treeNode: treeNode, skippingSubtree: heldSplitId
            )
        }
    }

    /// The parent size a divider plan may divide: the exact-fit render frame
    /// when one exists, bounded by the banked region on both axes. Pure and
    /// static so the plan(w) ≤ w invariant is testable without views.
    static func regionBoundedPlanParent(renderFrame: CGSize?, region: CGSize?) -> CGSize? {
        guard let parent = renderFrame ?? region else { return nil }
        guard let region else { return parent }
        return CGSize(
            width: min(parent.width, region.width),
            height: min(parent.height, region.height)
        )
    }

    /// The in-flight divider send's verdict against the CURRENT tmux tree:
    /// nil when no hold is active, the hold just resolved (the layout now
    /// assigns the sent span — the reply landed), or the held split no
    /// longer exists (the structure changed under the drag, so the hold is
    /// meaningless); otherwise the held split's id, which the imposition
    /// walk skips so an unrelated replan cannot bounce the user's divider.
    /// A never-answered send cannot keep returning non-nil here: the
    /// resize's own ack plus a barrier ack prove the no-op on the ordered
    /// control stream and release the hold (see judgeDividerResizeHold).
    private func resolveDividerResizeHold(
        tmuxTree: RemoteTmuxNativeSplitTree,
        treeNode: ExternalTreeNode
    ) -> UUID? {
        guard let hold = dividerResizeInFlight else { return nil }
        guard let assigned = assignedFirstSpan(
            forSplit: hold.splitId, axis: hold.axis,
            tmuxTree: tmuxTree, treeNode: treeNode
        ) else {
            dividerResizeInFlight = nil
            return nil
        }
        if assigned == hold.targetCells {
            dividerResizeInFlight = nil
            return nil
        }
        return hold.splitId
    }

    /// The cell span tmux currently assigns to the first subtree of the
    /// bonsplit split `splitId`, walking the bonsplit tree and the tmux tree
    /// in the same pairing every other walk uses. nil when the split cannot
    /// be found or the pairing drifted.
    func assignedFirstSpan(
        forSplit splitId: UUID,
        axis: RemoteTmuxSplitOrientation,
        tmuxTree: RemoteTmuxNativeSplitTree,
        treeNode: ExternalTreeNode
    ) -> Int? {
        guard case .split(let split) = treeNode,
              case .split(_, let orientation, let firstTree, let secondTree) = tmuxTree,
              split.orientation == orientation.treeName else { return nil }
        if UUID(uuidString: split.id) == splitId {
            guard orientation == axis else { return nil }
            return orientation == .horizontal
                ? firstTree.layout.width
                : firstTree.layout.height
        }
        return assignedFirstSpan(
            forSplit: splitId, axis: axis, tmuxTree: firstTree, treeNode: split.first
        ) ?? assignedFirstSpan(
            forSplit: splitId, axis: axis, tmuxTree: secondTree, treeNode: split.second
        )
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
        retryImposedExtents: Bool,
        skippingSubtree: UUID? = nil
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
        // A held split has a resize-pane in flight: its divider is the
        // user's committed drag and the tmux tree is pre-drag for it, so
        // imposing here would bounce the divider. The whole subtree keeps
        // its current geometry until the reply replans it.
        if let skippingSubtree, UUID(uuidString: split.id) == skippingSubtree {
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
            plan: firstPlan, treeNode: split.first,
            retryImposedExtents: retryImposedExtents, skippingSubtree: skippingSubtree
        )
        applyDividerPositions(
            plan: secondPlan, treeNode: split.second,
            retryImposedExtents: retryImposedExtents, skippingSubtree: skippingSubtree
        )
    }

    func applyFallbackDividerPositions(
        tmuxTree: RemoteTmuxNativeSplitTree,
        treeNode: ExternalTreeNode,
        skippingSubtree: UUID? = nil
    ) {
        guard case .split(let split) = treeNode,
              case .split(_, let orientation, let firstTree, let secondTree) = tmuxTree,
              split.orientation == orientation.treeName,
              let splitId = UUID(uuidString: split.id) else { return }
        if splitId == skippingSubtree { return }
        let fraction = Self.dividerFraction(
            first: firstTree.layout,
            rest: [secondTree.layout],
            horizontal: orientation == .horizontal
        )
        _ = bonsplitController.setImposedFirstExtent(nil, forSplit: splitId, fromExternal: true)
        _ = bonsplitController.setDividerPosition(fraction, forSplit: splitId, fromExternal: true)
        lastDividerPositions[splitId] = fraction
        applyFallbackDividerPositions(
            tmuxTree: firstTree, treeNode: split.first, skippingSubtree: skippingSubtree
        )
        applyFallbackDividerPositions(
            tmuxTree: secondTree, treeNode: split.second, skippingSubtree: skippingSubtree
        )
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
            _ = requestSplit(fromPane: tmuxPane, vertical: orientation == .vertical, focusIntent: .focusCreatedPane)
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
        // Mid-drag fractions are transients; the session end syncs the final
        // one. Without this, foreign-resize notifications from sibling splits
        // would convert the in-flight drag fraction to cells on every event.
        guard !controller.isDividerDragActive else { return }
        _ = syncChangedDividerPositions()
    }

    func splitTabBarDividerDragDidBegin(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
            owner: controller,
            in: NSApp.currentEvent?.window ?? visibleHostingContext()?.window
        )
        dividerResizeSentSinceDragBegan = false
        // An imposition that moved a divider parks its baseline at nil,
        // waiting for a post-layout geometry callback to record the clamped
        // outcome — but that callback can never arrive: the deferred apply
        // runs under the programmatic-sync guard (didResize returns before
        // onGeometryChange fires), and once the drag is live the drag guard
        // eats every callback. By drag begin the deferred apply HAS landed,
        // so the model fraction IS the outcome the nil was waiting for.
        // Seed it now; otherwise drag end has no pre-drag fraction to diff
        // against, sends nothing, and re-imposes the pre-drag extent — the
        // divider snaps back in the user's hand.
        seedMissingDividerBaselines(from: controller.treeSnapshot())
    }

    private func seedMissingDividerBaselines(from treeNode: ExternalTreeNode) {
        guard case .split(let split) = treeNode else { return }
        if let splitId = UUID(uuidString: split.id), lastDividerPositions[splitId] == nil {
            lastDividerPositions[splitId] = CGFloat(split.dividerPosition)
        }
        seedMissingDividerBaselines(from: split.first)
        seedMissingDividerBaselines(from: split.second)
    }

    func splitTabBarDividerDragDidEnd(_ controller: BonsplitController) {
        defer { TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: controller) }
        // A drag ending while a remote layout is being applied cannot run the
        // divider sync mid-apply: the apply is rewriting the tree this send
        // would diff against. Skipping the send outright loses the user's final
        // divider position — it never reaches tmux, and the scheduled sizing
        // pass then re-imposes the pre-drag plan. Defer the same drag-end send
        // one runloop turn, after the apply's synchronous scope clears the
        // flag; a coalesced no-op if the fraction rounds to the same cells.
        guard !isApplyingRemoteLayout else {
            setNeedsSizingPass()
            DispatchQueue.main.async { [weak self] in
                self?.flushDeferredDividerDragEnd()
            }
            return
        }
        sendDividerDragEnd(controller)
    }

    /// Runs the drag-end send once the remote apply that deferred it has
    /// cleared. Still applying (a re-entered apply) reschedules; otherwise it
    /// converts the final divider fraction and sends it, exactly as an
    /// undeferred drag end would.
    private func flushDeferredDividerDragEnd() {
        guard !isTornDown else { return }
        guard !isApplyingRemoteLayout else {
            DispatchQueue.main.async { [weak self] in
                self?.flushDeferredDividerDragEnd()
            }
            return
        }
        sendDividerDragEnd(bonsplitController)
    }

    private func sendDividerDragEnd(_ controller: BonsplitController) {
        // Bonsplit's final drag geometry notification lands just before this
        // callback and usually does the send; the re-sync here is the
        // fallback for a host that suppressed it. Either path counts. The
        // fraction here is the user's committed move, so a missing baseline
        // must not gate the send — the cells-versus-assigned check is the
        // real no-op detector.
        let sent = syncChangedDividerPositions(sendWithoutBaseline: true)
            || dividerResizeSentSinceDragBegan
        dividerResizeSentSinceDragBegan = false
        #if DEBUG
        cmuxDebugLog("remote.divider.dragEnd @\(windowId) sent=\(sent ? 1 : 0)")
        #endif
        if sent {
            // The resize-pane is out; tmux's layout reply is the settled
            // truth and re-imposes when it lands. Imposing the pre-drag tree
            // now would snap the divider back for a beat. A pass held
            // mid-drag still runs — its inputs changed independently.
            //
            // The plan is also known-stale until that reply: the output-parity
            // re-arm compares hosted frames (the user's dragged position)
            // against lastPlannedOuterSizes (the pre-drag plan), read a miss,
            // and re-imposed the stale plan — a visible bounce before the
            // reply's jump. The send recorded a keyed hold
            // (dividerResizeInFlight) that parks the re-arm and shields the
            // dragged split until the reply assigns the sent span.
            setNeedsSizingPass()
        } else {
            // Nothing to ask tmux (the drag rounded to the same cells), but
            // the drag cleared the split's imposition, so identical inputs no
            // longer mean the views hold the plan — re-impose regardless.
            setNeedsSizingPassIgnoringInputs()
        }
    }
}
