import CoreGraphics
import Foundation

extension WorkspaceLayoutController {
    // MARK: - Private Helpers

    var focusedPane: PaneState? {
        guard let focusedPaneId else { return nil }
        return rootNode.findPane(focusedPaneId)
    }

    var zoomedNode: SplitNode? {
        guard let zoomedPaneId else { return nil }
        return rootNode.findNode(containing: zoomedPaneId)
    }

    func setFocusedPane(_ paneId: PaneID) {
        guard rootNode.findPane(paneId) != nil else { return }
#if DEBUG
        dlog("focus.WorkspaceLayout pane=\(paneId.id.uuidString.prefix(5))")
#endif
        focusedPaneId = paneId
    }

    @discardableResult
    func clearPaneZoomInternal() -> Bool {
        guard zoomedPaneId != nil else { return false }
        zoomedPaneId = nil
        return true
    }

    @discardableResult
    func togglePaneZoomInternal(_ paneId: PaneID) -> Bool {
        guard rootNode.findPane(paneId) != nil else { return false }

        if zoomedPaneId == paneId {
            zoomedPaneId = nil
            return true
        }

        guard rootNode.allPaneIds.count > 1 else { return false }
        zoomedPaneId = paneId
        focusedPaneId = paneId
        return true
    }

    func performSplitPane(
        _ paneId: PaneID,
        orientation: SplitOrientation,
        with newTabId: UUID? = nil,
        focusNewPane: Bool = true
    ) {
        clearPaneZoomInternal()
        rootNode = splitNodeRecursively(
            node: rootNode,
            targetPaneId: paneId,
            orientation: orientation,
            newTabId: newTabId,
            focusNewPane: focusNewPane
        )
    }

    func splitNodeRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        newTabId: UUID?,
        focusNewPane: Bool
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                let newPane: PaneState
                if let newTabId {
                    newPane = PaneState(tabIds: [newTabId])
                } else {
                    newPane = PaneState()
                }

                let splitState = SplitState(
                    orientation: orientation,
                    first: .pane(paneState),
                    second: .pane(newPane),
                    dividerPosition: 0.5,
                    animationOrigin: .fromSecond
                )

                if focusNewPane {
                    focusedPaneId = newPane.id
                }

                return .split(splitState)
            }
            return node

        case .split(let splitState):
            var splitState = splitState
            splitState.first = splitNodeRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTabId: newTabId,
                focusNewPane: focusNewPane
            )
            splitState.second = splitNodeRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTabId: newTabId,
                focusNewPane: focusNewPane
            )
            return .split(splitState)
        }
    }

    func performSplitPaneWithTab(
        _ paneId: PaneID,
        orientation: SplitOrientation,
        tabId: UUID,
        insertFirst: Bool,
        focusNewPane: Bool = true
    ) {
        clearPaneZoomInternal()
        rootNode = splitNodeWithTabRecursively(
            node: rootNode,
            targetPaneId: paneId,
            orientation: orientation,
            tabId: tabId,
            insertFirst: insertFirst,
            focusNewPane: focusNewPane
        )
    }

    func splitNodeWithTabRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        tabId: UUID,
        insertFirst: Bool,
        focusNewPane: Bool
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                let newPane = PaneState(tabIds: [tabId])
                let splitState: SplitState
                if insertFirst {
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(newPane),
                        second: .pane(paneState),
                        dividerPosition: 0.5,
                        animationOrigin: .fromFirst
                    )
                } else {
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(paneState),
                        second: .pane(newPane),
                        dividerPosition: 0.5,
                        animationOrigin: .fromSecond
                    )
                }

                if focusNewPane {
                    focusedPaneId = newPane.id
                }

                return .split(splitState)
            }
            return node

        case .split(let splitState):
            var splitState = splitState
            splitState.first = splitNodeWithTabRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tabId: tabId,
                insertFirst: insertFirst,
                focusNewPane: focusNewPane
            )
            splitState.second = splitNodeWithTabRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tabId: tabId,
                insertFirst: insertFirst,
                focusNewPane: focusNewPane
            )
            return .split(splitState)
        }
    }

    func performClosePane(_ paneId: PaneID) {
        guard rootNode.findPane(paneId) != nil else { return }
        if rootNode.allPaneIds.count <= 1 {
            guard configuration.allowCloseLastPane else { return }
            let replacementPane = PaneState()
            rootNode = .pane(replacementPane)
            focusedPaneId = replacementPane.id
            zoomedPaneId = nil
            return
        }

        let (newRoot, siblingPaneId) = closePaneRecursively(node: rootNode, targetPaneId: paneId)

        if let newRoot {
            rootNode = newRoot
        }

        if let siblingPaneId {
            focusedPaneId = siblingPaneId
        } else if let firstPane = rootNode.allPaneIds.first {
            focusedPaneId = firstPane
        }

        if let zoomedPaneId, rootNode.findPane(zoomedPaneId) == nil {
            self.zoomedPaneId = nil
        }
    }

    func closePaneRecursively(
        node: SplitNode,
        targetPaneId: PaneID
    ) -> (SplitNode?, PaneID?) {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                return (nil, nil)
            }
            return (node, nil)

        case .split(let splitState):
            if case .pane(let firstPane) = splitState.first, firstPane.id == targetPaneId {
                let focusTarget = splitState.second.allPaneIds.first
                return (splitState.second, focusTarget)
            }

            if case .pane(let secondPane) = splitState.second, secondPane.id == targetPaneId {
                let focusTarget = splitState.first.allPaneIds.first
                return (splitState.first, focusTarget)
            }

            let (newFirst, focusFromFirst) = closePaneRecursively(node: splitState.first, targetPaneId: targetPaneId)
            if newFirst == nil {
                return (splitState.second, splitState.second.allPaneIds.first)
            }

            let (newSecond, focusFromSecond) = closePaneRecursively(node: splitState.second, targetPaneId: targetPaneId)
            if newSecond == nil {
                return (splitState.first, splitState.first.allPaneIds.first)
            }

            var updatedSplit = splitState
            if let newFirst { updatedSplit.first = newFirst }
            if let newSecond { updatedSplit.second = newSecond }

            return (.split(updatedSplit), focusFromFirst ?? focusFromSecond)
        }
    }

    func addTabInternal(
        _ tabId: UUID,
        toPane paneId: PaneID? = nil,
        atIndex index: Int? = nil,
        select: Bool = true
    ) {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return }

        rootNode.updatePane(targetPaneId) { pane in
            if let index {
                pane.insertTab(tabId, at: index, select: select)
            } else {
                pane.addTab(tabId, select: select)
            }
        }
    }

    func performMoveTab(_ tabId: UUID, from sourcePaneId: PaneID, to targetPaneId: PaneID, atIndex index: Int? = nil) {
        guard rootNode.findPane(sourcePaneId) != nil,
              rootNode.findPane(targetPaneId) != nil else { return }

        rootNode.updatePane(sourcePaneId) { pane in
            pane.removeTab(tabId)
        }

        rootNode.updatePane(targetPaneId) { pane in
            if let index {
                pane.insertTab(tabId, at: index)
            } else {
                pane.addTab(tabId)
            }
        }

        setFocusedPane(targetPaneId)

        if configuration.autoCloseEmptyPanes,
           rootNode.findPane(sourcePaneId)?.tabIds.isEmpty == true,
           rootNode.allPaneIds.count > 1 {
            performClosePane(sourcePaneId)
        }
    }

    func performCloseTab(_ tabId: UUID, inPane paneId: PaneID) {
        guard rootNode.findPane(paneId) != nil else { return }

        rootNode.updatePane(paneId) { pane in
            pane.removeTab(tabId)
        }

        if configuration.autoCloseEmptyPanes,
           rootNode.findPane(paneId)?.tabIds.isEmpty == true,
           (configuration.allowCloseLastPane || rootNode.allPaneIds.count > 1) {
            performClosePane(paneId)
        }
    }

    func performNavigateFocus(direction: NavigationDirection) {
        guard let currentPaneId = focusedPaneId else { return }

        let allPaneBounds = rootNode.computePaneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == currentPaneId })?.bounds else { return }

        if let targetPaneId = findBestNeighbor(
            from: currentBounds,
            currentPaneId: currentPaneId,
            direction: direction,
            allPaneBounds: allPaneBounds
        ) {
            setFocusedPane(targetPaneId)
        }
    }

    func adjacentPaneInternal(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        let allPaneBounds = rootNode.computePaneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == paneId })?.bounds else {
            return nil
        }
        return findBestNeighbor(
            from: currentBounds,
            currentPaneId: paneId,
            direction: direction,
            allPaneBounds: allPaneBounds
        )
    }

    func findBestNeighbor(
        from currentBounds: CGRect,
        currentPaneId: PaneID,
        direction: NavigationDirection,
        allPaneBounds: [PaneBounds]
    ) -> PaneID? {
        let epsilon: CGFloat = 0.001

        let candidates = allPaneBounds.filter { paneBounds in
            guard paneBounds.paneId != currentPaneId else { return false }
            let bounds = paneBounds.bounds
            switch direction {
            case .left: return bounds.maxX <= currentBounds.minX + epsilon
            case .right: return bounds.minX >= currentBounds.maxX - epsilon
            case .up: return bounds.maxY <= currentBounds.minY + epsilon
            case .down: return bounds.minY >= currentBounds.maxY - epsilon
            }
        }

        guard !candidates.isEmpty else { return nil }

        let scored: [(PaneID, CGFloat, CGFloat)] = candidates.map { candidate in
            let overlap: CGFloat
            let distance: CGFloat

            switch direction {
            case .left, .right:
                overlap = max(0, min(currentBounds.maxY, candidate.bounds.maxY) - max(currentBounds.minY, candidate.bounds.minY))
                distance = direction == .left
                    ? (currentBounds.minX - candidate.bounds.maxX)
                    : (candidate.bounds.minX - currentBounds.maxX)
            case .up, .down:
                overlap = max(0, min(currentBounds.maxX, candidate.bounds.maxX) - max(currentBounds.minX, candidate.bounds.minX))
                distance = direction == .up
                    ? (currentBounds.minY - candidate.bounds.maxY)
                    : (candidate.bounds.minY - currentBounds.maxY)
            }

            return (candidate.paneId, overlap, distance)
        }

        return scored.sorted { lhs, rhs in
            if abs(lhs.1 - rhs.1) > epsilon {
                return lhs.1 > rhs.1
            }
            return lhs.2 < rhs.2
        }.first?.0
    }

    func selectPreviousTabInternal() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabIds.firstIndex(of: selectedTabId),
              !pane.tabIds.isEmpty else { return }

        let newIndex = currentIndex > 0 ? currentIndex - 1 : pane.tabIds.count - 1
        rootNode.updatePane(pane.id) { pane in
            pane.selectTab(pane.tabIds[newIndex])
        }
    }

    func selectNextTabInternal() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabIds.firstIndex(of: selectedTabId),
              !pane.tabIds.isEmpty else { return }

        let newIndex = currentIndex < pane.tabIds.count - 1 ? currentIndex + 1 : 0
        rootNode.updatePane(pane.id) { pane in
            pane.selectTab(pane.tabIds[newIndex])
        }
    }

    func splitState(_ splitId: UUID) -> SplitState? {
        rootNode.findSplit(splitId)
    }

    func findTabInternal(_ tabId: TabID) -> (PaneID, Int)? {
        rootNode.findTab(tabId)
    }

    func notifyTabSelection() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId else { return }
        delegate?.workspaceSplit(didSelectTab: TabID(id: selectedTabId), inPane: pane.id)
    }
}
