import AppKit
import Bonsplit
import CmuxNestedTopology
import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteHerdrWindowMirrorHost {
    static func makeController(configuration: BonsplitConfiguration) -> BonsplitController {
        BonsplitController(configuration: configuration.remoteTmuxEmbedded)
    }

    func configureBonsplitController() {
        bonsplitController.delegate = self
        bonsplitController.tabShortcutHintsEnabled = false
        bonsplitController.onExternalTabDrop = { _ in false }
    }

    func rebuildBonsplitTree() {
        beginApplyingRemoteLayout()
        defer { endApplyingRemoteLayout() }
        resetToSingleEmptyPane()
        tabIdByPaneId.removeAll()
        paneIdByPaneId.removeAll()
        paneIdByBonsplitPane.removeAll()
        paneIdByTabId.removeAll()
        guard let rootPane = bonsplitController.allPaneIds.first,
              let rendered = renderedLayout
        else { return }
        _ = build(rendered, inPane: rootPane)
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
    func build(_ node: RemoteHerdrLayoutNode, inPane pane: PaneID) -> PaneID? {
        switch node.content {
        case .pane(let paneID):
            guard panelsByPaneId[paneID] != nil else { return nil }
            guard let tabId = bonsplitController.createTab(
                title: title(forPane: paneID),
                icon: "terminal",
                kind: "terminal",
                inPane: pane
            ) else { return nil }
            tabIdByPaneId[paneID] = tabId
            paneIdByPaneId[paneID] = pane
            paneIdByBonsplitPane[pane] = paneID
            paneIdByTabId[tabId] = paneID
            return pane
        case .horizontal(let children):
            return build(children: children, orientation: .horizontal, inPane: pane)
        case .vertical(let children):
            return build(children: children, orientation: .vertical, inPane: pane)
        }
    }

    func build(
        children: [RemoteHerdrLayoutNode],
        orientation: SplitOrientation,
        inPane pane: PaneID
    ) -> PaneID? {
        guard let first = children.first else { return nil }
        guard children.count > 1 else { return build(first, inPane: pane) }
        let rest = Array(children.dropFirst())
        let fraction = dividerFraction(first: first, rest: rest, orientation: orientation)
        guard let restPane = bonsplitController.splitPane(
            pane,
            orientation: orientation,
            withTab: nil,
            initialDividerPosition: fraction
        ) else { return build(first, inPane: pane) }
        _ = build(first, inPane: pane)
        if let restNode = combined(children: rest, orientation: orientation) {
            _ = build(restNode, inPane: restPane)
        }
        return pane
    }

    func combined(children: [RemoteHerdrLayoutNode], orientation: SplitOrientation) -> RemoteHerdrLayoutNode? {
        guard let first = children.first else {
            return nil
        }
        guard children.count > 1 else { return first }
        let width = children.map(\.width).reduce(0, +)
        let height = children.map(\.height).max() ?? first.height
        switch orientation {
        case .horizontal:
            return RemoteHerdrLayoutNode(
                width: max(1, width),
                height: max(1, height),
                x: first.x,
                y: first.y,
                content: .horizontal(children)
            )
        case .vertical:
            let h = children.map(\.height).reduce(0, +)
            let w = children.map(\.width).max() ?? first.width
            return RemoteHerdrLayoutNode(
                width: max(1, w),
                height: max(1, h),
                x: first.x,
                y: first.y,
                content: .vertical(children)
            )
        }
    }

    func dividerFraction(
        first: RemoteHerdrLayoutNode,
        rest: [RemoteHerdrLayoutNode],
        orientation: SplitOrientation
    ) -> CGFloat {
        let firstSpan = orientation == .horizontal ? first.width : first.height
        let restSpans = rest.map { orientation == .horizontal ? $0.width : $0.height }
        return CGFloat(RemoteHerdrImpose.dividerFraction(firstSpan: firstSpan, restSpans: restSpans))
    }

    func title(forPane paneID: String) -> String {
        "\(windowTitle) · \(paneID)"
    }

    func expandLeaf(
        existingPaneID: String,
        newPaneID: String,
        orientation: RemoteHerdrSplitOrientation,
        insertFirst: Bool,
        fraction: Double
    ) {
        guard let existingPane = paneIdByPaneId[existingPaneID] else {
            rebuildBonsplitTree()
            return
        }
        let bonsplitOrientation: SplitOrientation =
            orientation == .horizontal ? .horizontal : .vertical
        let clamped = RemoteHerdrImpose.clampRatio(fraction)
        guard let newPane = bonsplitController.splitPane(
            existingPane,
            orientation: bonsplitOrientation,
            withTab: nil,
            initialDividerPosition: CGFloat(insertFirst ? (1.0 - clamped) : clamped)
        ) else {
            rebuildBonsplitTree()
            return
        }
        let targetPane = insertFirst ? existingPane : newPane
        // Ensure panel exists before building the leaf tab.
        if createPanelIfNeeded(paneID: newPaneID) == nil { return }
        guard let tabId = bonsplitController.createTab(
            title: title(forPane: newPaneID),
            icon: "terminal",
            kind: "terminal",
            inPane: targetPane
        ) else { return }
        tabIdByPaneId[newPaneID] = tabId
        paneIdByPaneId[newPaneID] = targetPane
        paneIdByBonsplitPane[targetPane] = newPaneID
        paneIdByTabId[tabId] = newPaneID
    }

    func removeLeaf(paneID: String) {
        guard let pane = paneIdByPaneId[paneID] else {
            rebuildBonsplitTree()
            return
        }
        var index = RemoteHerdrTabPaneIndex(
            tabIdByPaneId: tabIdByPaneId,
            paneIdByTabId: paneIdByTabId
        )
        let tabId = index.removeLeaf(paneID: paneID)
        tabIdByPaneId = index.tabIdByPaneId
        paneIdByTabId = index.paneIdByTabId
        if let tabId {
            _ = bonsplitController.closeTab(tabId, inPane: pane)
        }
        if bonsplitController.allPaneIds.count > 1 {
            _ = bonsplitController.closePane(pane)
        }
        paneIdByPaneId.removeValue(forKey: paneID)
        paneIdByBonsplitPane.removeValue(forKey: pane)
    }

    func beginApplyingRemoteLayout() {
        applyingRemoteLayoutDepth += 1
        isApplyingRemoteLayout = true
    }

    func endApplyingRemoteLayout() {
        applyingRemoteLayoutDepth = max(0, applyingRemoteLayoutDepth - 1)
        guard applyingRemoteLayoutDepth == 0 else { return }
        isApplyingRemoteLayout = false
        if pendingDividerDragEnd {
            pendingDividerDragEnd = false
            sendDividerDragEnd(bonsplitController)
        }
    }

    /// Walk the binary divider tree in lockstep with Bonsplit and impose fractions.
    func imposeDividerTree(_ node: RemoteHerdrDividerNode) {
        let treeNode = bonsplitController.treeSnapshot()
        impose(node, onto: treeNode)
    }

    private func impose(_ node: RemoteHerdrDividerNode, onto treeNode: ExternalTreeNode) {
        switch (node, treeNode) {
        case (.leaf, .pane):
            return
        case let (
            .split(orientation, fraction, firstExtent, first, second),
            .split(let split)
        ):
            let expected: String = orientation == .horizontal ? "horizontal" : "vertical"
            guard split.orientation == expected,
                  let splitId = UUID(uuidString: split.id)
            else { return }
            if let firstExtent {
                _ = bonsplitController.setImposedFirstExtent(
                    CGFloat(firstExtent), forSplit: splitId, fromExternal: true
                )
            } else {
                let clamped = CGFloat(RemoteHerdrImpose.clampRatio(fraction))
                _ = bonsplitController.setDividerPosition(
                    clamped, forSplit: splitId, fromExternal: true
                )
                lastDividerPositions[splitId] = clamped
            }
            impose(first, onto: split.first)
            impose(second, onto: split.second)
        default:
            return
        }
    }
}

// MARK: - BonsplitDelegate (tmux RemoteTmuxWindowMirror+Bonsplit)

extension RemoteHerdrWindowMirrorHost: BonsplitDelegate {
    func splitTabBar(
        _ controller: BonsplitController,
        shouldCloseTab tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) -> Bool {
        guard !isApplyingRemoteLayout else { return true }
        if let herdrPane = paneIdByTabId[tab.id] {
            onClosePaneRequest?(herdrPane)
        }
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
        if let herdrPane = paneIdByBonsplitPane[pane] {
            _ = requestSplit(fromPane: herdrPane, vertical: orientation == .vertical)
        }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard !isApplyingRemoteLayout, !isApplyingFocus,
              let herdrPane = paneIdByBonsplitPane[pane],
              activePaneID != herdrPane else { return }
        focus(pane: herdrPane)
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        guard !isApplyingRemoteLayout else { return }
        guard !controller.isDividerDragActive else { return }
        _ = syncChangedDividerPositions()
    }

    func splitTabBarDividerDragDidBegin(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
            owner: controller,
            in: NSApp.currentEvent?.window ?? visibleHostingWindow()
        )
        dividerResizeSentSinceDragBegan = false
        seedMissingDividerBaselines(from: controller.treeSnapshot())
    }

    func splitTabBarDividerDragDidEnd(_ controller: BonsplitController) {
        defer { TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: controller) }
        guard !isApplyingRemoteLayout else {
            pendingDividerDragEnd = true
            setNeedsSizingPass()
            return
        }
        sendDividerDragEnd(controller)
    }

    private func seedMissingDividerBaselines(from treeNode: ExternalTreeNode) {
        guard case .split(let split) = treeNode else { return }
        if let splitId = UUID(uuidString: split.id), lastDividerPositions[splitId] == nil {
            lastDividerPositions[splitId] = CGFloat(split.dividerPosition)
        }
        seedMissingDividerBaselines(from: split.first)
        seedMissingDividerBaselines(from: split.second)
    }

    private func sendDividerDragEnd(_ controller: BonsplitController) {
        _ = syncChangedDividerPositions(sendWithoutBaseline: true)
            || dividerResizeSentSinceDragBegan
        dividerResizeSentSinceDragBegan = false
        setNeedsSizingPass()
    }
}
