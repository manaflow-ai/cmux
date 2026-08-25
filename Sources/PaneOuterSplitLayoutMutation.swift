import Bonsplit
import Foundation

/// Shared structural mutation used by the main workspace and the right-side
/// Dock. Bonsplit intentionally exposes leaf-level split operations, while an
/// outer-pane move needs to preserve an existing tree around the workspace
/// root. This implementation rebuilds the tree from live tab metadata, so the
/// tab and panel objects themselves are transferred rather than recreated.
@MainActor
enum PaneOuterSplitLayoutMutation {
    typealias Splitter = @MainActor (
        _ pane: PaneID,
        _ orientation: SplitOrientation,
        _ tab: Bonsplit.Tab,
        _ insertFirst: Bool
    ) -> PaneID?

    private struct LayoutPane {
        let id: PaneID
        let tabIds: [TabID]
        let selectedTabId: TabID?
        let isFullWidthTabMode: Bool
    }

    private struct LayoutSplit {
        let orientation: SplitOrientation
        let dividerPosition: CGFloat
        let first: LayoutNode
        let second: LayoutNode
    }

    private indirect enum LayoutNode {
        case pane(LayoutPane)
        case split(LayoutSplit)

        var paneCount: Int {
            switch self {
            case .pane: 1
            case .split(let split): split.first.paneCount + split.second.paneCount
            }
        }

        func contains(paneId: PaneID) -> Bool {
            switch self {
            case .pane(let pane): pane.id == paneId
            case .split(let split):
                split.first.contains(paneId: paneId)
                    || split.second.contains(paneId: paneId)
            }
        }

        func pane(withId paneId: PaneID) -> LayoutPane? {
            switch self {
            case .pane(let pane):
                return pane.id == paneId ? pane : nil
            case .split(let split):
                return split.first.pane(withId: paneId)
                    ?? split.second.pane(withId: paneId)
            }
        }

        var leaves: [LayoutPane] {
            switch self {
            case .pane(let pane): [pane]
            case .split(let split): split.first.leaves + split.second.leaves
            }
        }
    }

    /// Promotes `paneId` to a new root edge split. The splitter closure lets
    /// each host mark its own programmatic-split transaction, preventing its
    /// delegate from creating an extra terminal in each scaffold pane.
    @discardableResult
    static func movePane(
        _ paneId: PaneID,
        in controller: BonsplitController,
        movement: PaneOuterSplitMovement,
        split: @escaping Splitter
    ) -> Bool {
        guard controller.configuration.allowSplits,
              controller.configuration.allowCrossPaneTabMove,
              let layout = captureLayout(from: controller.treeSnapshot(), controller: controller),
              layout.paneCount > 1,
              let sourcePane = layout.pane(withId: paneId),
              !sourcePane.tabIds.isEmpty,
              layout.contains(paneId: paneId),
              !isAlreadyAtRequestedRootEdge(
                  layout,
                  paneId: paneId,
                  movement: movement
              ) else {
            return false
        }

        // Every normal cmux pane owns at least one live surface. Refuse a
        // transient empty tree rather than risk collapsing a pane while the
        // live tabs are being redistributed.
        guard layout.leaves.allSatisfy({ !$0.tabIds.isEmpty }) else {
            return false
        }

        var removedSource: LayoutNode?
        guard let remaining = removing(
            paneId: paneId,
            from: layout,
            removed: &removedSource
        ), let removedSource else {
            return false
        }

        let desiredLayout: LayoutNode
        let rootSplit = LayoutSplit(
            orientation: movement.orientation,
            dividerPosition: 0.5,
            first: movement.insertFirst ? removedSource : remaining,
            second: movement.insertFirst ? remaining : removedSource
        )
        desiredLayout = .split(rootSplit)

        // Collapse the old tree into the source pane while retaining every
        // existing TabID. Bonsplit closes emptied source leaves internally;
        // no panel close callbacks are emitted because the tabs are moved,
        // not closed.
        let existingPaneIds = controller.allPaneIds
        for existingPaneId in existingPaneIds where existingPaneId != paneId {
            let tabs = controller.tabs(inPane: existingPaneId)
            for tab in tabs {
                let insertionIndex = controller.tabs(inPane: paneId).count
                guard controller.moveTab(
                    tab.id,
                    toPane: paneId,
                    atIndex: insertionIndex
                ) else {
                    return false
                }
            }
        }

        _ = controller.clearPaneZoom()

        var generatedPaneByOriginalPane: [PaneID: PaneID] = [:]
        var placeholderByGeneratedPane: [PaneID: TabID] = [:]

        func build(_ node: LayoutNode, in pane: PaneID) -> Bool {
            switch node {
            case .pane(let layoutPane):
                generatedPaneByOriginalPane[layoutPane.id] = pane
                return true

            case .split(let layoutSplit):
                let placeholder = Bonsplit.Tab(
                    title: "",
                    icon: nil,
                    kind: "cmux.outerSplit.placeholder"
                )

                // Keep the existing pane on the branch containing the source
                // pane. For branches unrelated to the source, retaining the
                // existing pane as the first child preserves child order.
                let containsSource = node.contains(paneId: paneId)
                let sourceInFirst = layoutSplit.first.contains(paneId: paneId)
                let keepExistingPane = !containsSource || sourceInFirst
                let insertPlaceholderFirst = !keepExistingPane
                guard let newPane = split(
                    pane,
                    layoutSplit.orientation,
                    placeholder,
                    insertPlaceholderFirst
                ) else {
                    return false
                }
                placeholderByGeneratedPane[newPane] = placeholder.id

                if keepExistingPane {
                    return build(layoutSplit.first, in: pane)
                        && build(layoutSplit.second, in: newPane)
                }
                return build(layoutSplit.first, in: newPane)
                    && build(layoutSplit.second, in: pane)
            }
        }

        guard build(desiredLayout, in: paneId),
              generatedPaneByOriginalPane.count == desiredLayout.paneCount else {
            return false
        }

        applyDividerPositions(
            desired: desiredLayout,
            live: controller.treeSnapshot(),
            controller: controller
        )

        // Move each pane's tabs in their original order. The source pane is
        // deliberately left with its desired tabs until the end so Bonsplit's
        // automatic empty-source collapse cannot remove the preserved source
        // pane identity.
        for layoutPane in desiredLayout.leaves where layoutPane.id != paneId {
            guard let targetPane = generatedPaneByOriginalPane[layoutPane.id] else {
                return false
            }
            for tabId in layoutPane.tabIds {
                let insertionIndex = controller.tabs(inPane: targetPane).count
                guard controller.moveTab(
                    tabId,
                    toPane: targetPane,
                    atIndex: insertionIndex
                ) else {
                    return false
                }
            }
        }

        // Remove only our scaffolding tabs. Every real pane has at least one
        // live tab, so closing a placeholder cannot collapse the desired tree.
        for (targetPane, placeholderId) in placeholderByGeneratedPane {
            guard controller.allPaneIds.contains(targetPane) else { continue }
            _ = controller.closeTab(placeholderId)
        }

        for layoutPane in desiredLayout.leaves {
            guard let targetPane = generatedPaneByOriginalPane[layoutPane.id] else {
                continue
            }
            if controller.configuration.allowTabReordering {
                restoreTabOrder(
                    layoutPane.tabIds,
                    in: targetPane,
                    controller: controller
                )
            }
            _ = controller.setFullWidthTabMode(
                layoutPane.isFullWidthTabMode,
                inPane: targetPane
            )
            if let selectedTabId = layoutPane.selectedTabId,
               controller.tabs(inPane: targetPane).contains(where: { $0.id == selectedTabId }) {
                controller.selectTab(selectedTabId)
            }
        }

        guard let destinationSourcePane = generatedPaneByOriginalPane[paneId] else {
            return false
        }
        controller.focusPane(destinationSourcePane)
        if let selectedTabId = sourcePane.selectedTabId,
           controller.tabs(inPane: destinationSourcePane).contains(where: { $0.id == selectedTabId }) {
            controller.selectTab(selectedTabId)
        }
        return true
    }

    private static func captureLayout(
        from node: ExternalTreeNode,
        controller: BonsplitController
    ) -> LayoutNode? {
        switch node {
        case .pane(let pane):
            guard let uuid = UUID(uuidString: pane.id) else { return nil }
            let paneId = PaneID(id: uuid)
            let tabs = controller.tabs(inPane: paneId)
            guard !tabs.isEmpty else { return nil }
            return .pane(
                LayoutPane(
                    id: paneId,
                    tabIds: tabs.map(\.id),
                    selectedTabId: controller.selectedTab(inPane: paneId)?.id,
                    isFullWidthTabMode: controller.isFullWidthTabMode(inPane: paneId)
                )
            )

        case .split(let split):
            let orientation: SplitOrientation
            switch split.orientation.lowercased() {
            case "horizontal": orientation = .horizontal
            case "vertical": orientation = .vertical
            default: return nil
            }
            guard let first = captureLayout(from: split.first, controller: controller),
                  let second = captureLayout(from: split.second, controller: controller) else {
                return nil
            }
            return .split(
                LayoutSplit(
                    orientation: orientation,
                    dividerPosition: CGFloat(split.dividerPosition),
                    first: first,
                    second: second
                )
            )
        }
    }

    private static func isAlreadyAtRequestedRootEdge(
        _ layout: LayoutNode,
        paneId: PaneID,
        movement: PaneOuterSplitMovement
    ) -> Bool {
        guard case .split(let root) = layout,
              root.orientation == movement.orientation else {
            return false
        }
        let edge = movement.insertFirst ? root.first : root.second
        guard case .pane(let pane) = edge else { return false }
        return pane.id == paneId
    }

    private static func removing(
        paneId: PaneID,
        from node: LayoutNode,
        removed: inout LayoutNode?
    ) -> LayoutNode? {
        switch node {
        case .pane(let pane):
            guard pane.id == paneId else { return node }
            removed = node
            return nil

        case .split(let split):
            if split.first.contains(paneId: paneId) {
                guard let first = removing(
                    paneId: paneId,
                    from: split.first,
                    removed: &removed
                ) else {
                    return split.second
                }
                return .split(
                    LayoutSplit(
                        orientation: split.orientation,
                        dividerPosition: split.dividerPosition,
                        first: first,
                        second: split.second
                    )
                )
            }
            guard let second = removing(
                paneId: paneId,
                from: split.second,
                removed: &removed
            ) else {
                return split.first
            }
            return .split(
                LayoutSplit(
                    orientation: split.orientation,
                    dividerPosition: split.dividerPosition,
                    first: split.first,
                    second: second
                )
            )
        }
    }

    private static func applyDividerPositions(
        desired: LayoutNode,
        live: ExternalTreeNode,
        controller: BonsplitController
    ) {
        guard case .split(let desiredSplit) = desired,
              case .split(let liveSplit) = live else {
            return
        }
        if let splitId = UUID(uuidString: liveSplit.id) {
            _ = controller.setDividerPosition(
                desiredSplit.dividerPosition,
                forSplit: splitId
            )
        }
        applyDividerPositions(
            desired: desiredSplit.first,
            live: liveSplit.first,
            controller: controller
        )
        applyDividerPositions(
            desired: desiredSplit.second,
            live: liveSplit.second,
            controller: controller
        )
    }

    private static func restoreTabOrder(
        _ desiredTabIds: [TabID],
        in pane: PaneID,
        controller: BonsplitController
    ) {
        for (desiredIndex, tabId) in desiredTabIds.enumerated() {
            guard let currentIndex = controller.tabs(inPane: pane)
                .firstIndex(where: { $0.id == tabId }) else {
                continue
            }
            guard currentIndex != desiredIndex else { continue }
            let destinationIndex = currentIndex < desiredIndex
                ? desiredIndex + 1
                : desiredIndex
            _ = controller.reorderTab(tabId, toIndex: destinationIndex)
        }
    }
}
