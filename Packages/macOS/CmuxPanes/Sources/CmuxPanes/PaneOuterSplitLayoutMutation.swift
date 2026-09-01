public import Bonsplit
import Foundation

/// Performs the root-edge promotion used by workspace and Dock hosts.
@MainActor
public protocol PaneOuterSplitLayoutMutating {
    /// Host-owned split operation used to create each scaffold pane.
    typealias Splitter = @MainActor (
        _ pane: PaneID,
        _ orientation: SplitOrientation,
        _ tab: Bonsplit.Tab,
        _ insertFirst: Bool
    ) -> PaneID?

    /// Promotes `paneId` to the requested edge while preserving its live tabs.
    @discardableResult
    func movePane(
        _ paneId: PaneID,
        in controller: BonsplitController,
        movement: PaneOuterSplitMovement,
        split: @escaping Splitter
    ) -> Bool
}

/// Shared structural mutation used by the main workspace and the right-side
/// Dock. Bonsplit intentionally exposes leaf-level split operations, while an
/// outer-pane move needs to preserve an existing tree around the workspace
/// root. This implementation rebuilds the tree from live tab metadata, so the
/// tab and panel objects themselves are transferred rather than recreated.
@MainActor
public struct PaneOuterSplitLayoutMutation: PaneOuterSplitLayoutMutating {
    /// Creates the stateless outer-pane layout service.
    nonisolated public init() {}

    private struct LayoutPane {
        let id: PaneID
        let tabIds: [TabID]
        let selectedTabId: TabID?
        let isFullWidthTabMode: Bool
        let containsSource: Bool
    }

    private struct LayoutSplit {
        let orientation: SplitOrientation
        let dividerPosition: CGFloat
        let first: LayoutNode
        let second: LayoutNode
        let containsSource: Bool
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

        var containsSource: Bool {
            switch self {
            case .pane(let pane): pane.containsSource
            case .split(let split): split.containsSource
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

        func appendLeaves(to result: inout [LayoutPane]) {
            switch self {
            case .pane(let pane):
                result.append(pane)
            case .split(let split):
                split.first.appendLeaves(to: &result)
                split.second.appendLeaves(to: &result)
            }
        }
    }

    /// Promotes `paneId` to a new root edge split. The splitter closure lets
    /// each host mark its own programmatic-split transaction, preventing its
    /// delegate from creating an extra terminal in each scaffold pane.
    @discardableResult
    public func movePane(
        _ paneId: PaneID,
        in controller: BonsplitController,
        movement: PaneOuterSplitMovement,
        split: @escaping Splitter
    ) -> Bool {
        guard controller.configuration.allowSplits,
              controller.configuration.allowCrossPaneTabMove,
              let layout = captureLayout(
                  from: controller.treeSnapshot(),
                  controller: controller,
                  sourcePaneId: paneId
              ),
              layout.paneCount > 1,
              let sourcePane = layout.pane(withId: paneId),
              !sourcePane.tabIds.isEmpty,
              layout.containsSource,
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
        let capturedLeaves = leaves(of: layout)
        guard capturedLeaves.allSatisfy({ !$0.tabIds.isEmpty }) else {
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
            second: movement.insertFirst ? remaining : removedSource,
            containsSource: true
        )
        desiredLayout = .split(rootSplit)

        // Collapse the old tree into the source pane while retaining every
        // existing TabID. Bonsplit closes emptied source leaves internally;
        // no panel close callbacks are emitted because the tabs are moved,
        // not closed.
        let existingPaneIds = controller.allPaneIds
        let capturedTabIdsByPane = Dictionary(
            uniqueKeysWithValues: capturedLeaves.map { ($0.id, $0.tabIds) }
        )
        // Use the captured ownership/index snapshot to form one linear
        // transfer plan; live tab collections are not rescanned per item.
        var sourceInsertionIndex = sourcePane.tabIds.count
        for existingPaneId in existingPaneIds where existingPaneId != paneId {
            guard let tabIds = capturedTabIdsByPane[existingPaneId] else {
                return false
            }
            for tabId in tabIds {
                guard controller.moveTab(
                    tabId,
                    toPane: paneId,
                    atIndex: sourceInsertionIndex
                ) else {
                    return false
                }
                sourceInsertionIndex += 1
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
                let containsSource = node.containsSource
                let sourceInFirst = layoutSplit.first.containsSource
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
        let desiredLeaves = leaves(of: desiredLayout)
        for layoutPane in desiredLeaves where layoutPane.id != paneId {
            guard let targetPane = generatedPaneByOriginalPane[layoutPane.id] else {
                return false
            }
            guard placeholderByGeneratedPane[targetPane] != nil else {
                return false
            }
            var insertionIndex = 1
            for tabId in layoutPane.tabIds {
                guard controller.moveTab(
                    tabId,
                    toPane: targetPane,
                    atIndex: insertionIndex
                ) else {
                    return false
                }
                insertionIndex += 1
            }
        }

        // Remove only our scaffolding tabs. Every real pane has at least one
        // live tab, so closing a placeholder cannot collapse the desired tree.
        for (_, placeholderId) in placeholderByGeneratedPane {
            _ = controller.closeTab(placeholderId)
        }

        // Every generated pane starts with only its placeholder. Moving the
        // captured IDs in their original order at monotonically increasing
        // insertion indices therefore constructs each final tab order directly;
        // a second per-tab reorder pass would only repeat the same scans.
        for layoutPane in desiredLeaves {
            guard let targetPane = generatedPaneByOriginalPane[layoutPane.id] else {
                continue
            }
            _ = controller.setFullWidthTabMode(
                layoutPane.isFullWidthTabMode,
                inPane: targetPane
            )
            if let selectedTabId = layoutPane.selectedTabId {
                controller.selectTab(selectedTabId)
            }
        }

        guard let destinationSourcePane = generatedPaneByOriginalPane[paneId] else {
            return false
        }
        controller.focusPane(destinationSourcePane)
        if let selectedTabId = sourcePane.selectedTabId {
            controller.selectTab(selectedTabId)
        }
        return true
    }

    private func leaves(of node: LayoutNode) -> [LayoutPane] {
        var result: [LayoutPane] = []
        result.reserveCapacity(node.paneCount)
        node.appendLeaves(to: &result)
        return result
    }

    private func captureLayout(
        from node: ExternalTreeNode,
        controller: BonsplitController,
        sourcePaneId: PaneID
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
                    isFullWidthTabMode: controller.isFullWidthTabMode(inPane: paneId),
                    containsSource: paneId == sourcePaneId
                )
            )

        case .split(let split):
            let orientation: SplitOrientation
            switch split.orientation.lowercased() {
            case "horizontal": orientation = .horizontal
            case "vertical": orientation = .vertical
            default: return nil
            }
            guard let first = captureLayout(
                      from: split.first,
                      controller: controller,
                      sourcePaneId: sourcePaneId
                  ),
                  let second = captureLayout(
                      from: split.second,
                      controller: controller,
                      sourcePaneId: sourcePaneId
                  ) else {
                return nil
            }
            return .split(
                LayoutSplit(
                    orientation: orientation,
                    dividerPosition: CGFloat(split.dividerPosition),
                    first: first,
                    second: second,
                    containsSource: first.containsSource || second.containsSource
                )
            )
        }
    }

    private func isAlreadyAtRequestedRootEdge(
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

    private func removing(
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
            if split.first.containsSource {
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
                        second: split.second,
                        containsSource: first.containsSource || split.second.containsSource
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
                    second: second,
                    containsSource: split.first.containsSource || second.containsSource
                )
            )
        }
    }

    private func applyDividerPositions(
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

}
