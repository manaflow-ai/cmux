import Bonsplit
import CmuxPanes
import enum CmuxTerminalBackend.BackendSplitDirection
import Foundation

extension TabManager {
    private struct CanonicalSplitRatioRequest {
        let paneID: UUID
        let direction: BackendSplitDirection
        let ratio: Float
    }

    private struct LocalSplitRatioRequest {
        let splitID: UUID
        let ratio: CGFloat
    }

    /// Equalize splits - not directly supported by bonsplit.
    func equalizeSplits(tabId: UUID, orientationFilter: String? = nil) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        if tab.panels.keys.contains(where: tab.isBackendCanonicalPanel),
           let mutationCoordinator = terminalClientComposition.terminalBackendTopologyMutationCoordinator,
           !tab.isApplyingCanonicalTopologyProjection {
            let plan = backendEqualizePlan(
                in: tab.bonsplitController.treeSnapshot(),
                tab: tab,
                orientationFilter: orientationFilter
            )
            guard plan.foundSplit,
                  !plan.hadInvalidIdentity else {
                return false
            }
            for request in plan.localRequests {
                _ = tab.bonsplitController.setDividerPosition(
                    request.ratio,
                    forSplit: request.splitID,
                    fromExternal: true
                )
            }
            if !plan.localRequests.isEmpty {
                tab.didProgrammaticallyChangeSplitGeometry()
            }
            for request in plan.canonicalRequests {
                mutationCoordinator.requestSetSplitRatio(
                    around: request.paneID,
                    direction: request.direction,
                    ratio: request.ratio
                )
            }
            return true
        }

        let result = equalizeSplitsOnce(in: tab, orientationFilter: orientationFilter)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(
        in tab: Workspace,
        orientationFilter: String?
    ) -> SplitEqualizeResult {
        paneLayout.equalizeSplits(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController,
            orientationFilter: orientationFilter
        )
    }

    private func backendEqualizePlan(
        in node: ExternalTreeNode,
        tab: Workspace,
        orientationFilter: String?
    ) -> (
        canonicalRequests: [CanonicalSplitRatioRequest],
        localRequests: [LocalSplitRatioRequest],
        foundSplit: Bool,
        hadInvalidIdentity: Bool
    ) {
        switch node {
        case .pane:
            return ([], [], false, false)
        case .split(let split):
            let firstPlan = backendEqualizePlan(
                in: split.first,
                tab: tab,
                orientationFilter: orientationFilter
            )
            let secondPlan = backendEqualizePlan(
                in: split.second,
                tab: tab,
                orientationFilter: orientationFilter
            )
            var canonicalRequests = firstPlan.canonicalRequests + secondPlan.canonicalRequests
            var localRequests = firstPlan.localRequests + secondPlan.localRequests
            var foundSplit = firstPlan.foundSplit || secondPlan.foundSplit
            var hadInvalidIdentity = firstPlan.hadInvalidIdentity || secondPlan.hadInvalidIdentity
            if orientationFilter == nil || split.orientation == orientationFilter {
                foundSplit = true
                let firstIsCanonical = containsBackendCanonicalPanel(
                    in: split.first,
                    tab: tab
                )
                let secondIsCanonical = containsBackendCanonicalPanel(
                    in: split.second,
                    tab: tab
                )
                if firstIsCanonical && secondIsCanonical {
                    let firstSpan = canonicalSplitSpanCount(
                        split.first,
                        along: split.orientation,
                        tab: tab
                    )
                    let secondSpan = canonicalSplitSpanCount(
                        split.second,
                        along: split.orientation,
                        tab: tab
                    )
                    let ratio = Float(firstSpan) / Float(firstSpan + secondSpan)
                    if let paneID = positiveEdgeCanonicalPaneID(
                        in: split.first,
                        orientation: split.orientation,
                        tab: tab
                    ) {
                        canonicalRequests.append(CanonicalSplitRatioRequest(
                            paneID: paneID,
                            direction: split.orientation == "horizontal" ? .right : .down,
                            ratio: ratio
                        ))
                    } else {
                        hadInvalidIdentity = true
                    }
                } else if let splitID = UUID(uuidString: split.id) {
                    let firstSpan = visibleSplitSpanCount(split.first, along: split.orientation)
                    let secondSpan = visibleSplitSpanCount(split.second, along: split.orientation)
                    localRequests.append(LocalSplitRatioRequest(
                        splitID: splitID,
                        ratio: CGFloat(firstSpan) / CGFloat(firstSpan + secondSpan)
                    ))
                } else {
                    hadInvalidIdentity = true
                }
            }
            return (canonicalRequests, localRequests, foundSplit, hadInvalidIdentity)
        }
    }

    private func visibleSplitSpanCount(_ node: ExternalTreeNode, along orientation: String) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let split) where split.orientation == orientation:
            return visibleSplitSpanCount(split.first, along: orientation)
                + visibleSplitSpanCount(split.second, along: orientation)
        case .split:
            return 1
        }
    }

    private func canonicalSplitSpanCount(
        _ node: ExternalTreeNode,
        along orientation: String,
        tab: Workspace
    ) -> Int {
        guard containsBackendCanonicalPanel(in: node, tab: tab) else { return 0 }
        switch node {
        case .pane:
            return 1
        case .split(let split) where split.orientation == orientation:
            return canonicalSplitSpanCount(split.first, along: orientation, tab: tab)
                + canonicalSplitSpanCount(split.second, along: orientation, tab: tab)
        case .split:
            return 1
        }
    }

    /// Returns a leaf on the right or bottom edge. Addressing that leaf's
    /// positive edge selects the parent split rather than a nested split.
    private func positiveEdgeCanonicalPaneID(
        in node: ExternalTreeNode,
        orientation: String,
        tab: Workspace
    ) -> UUID? {
        switch node {
        case .pane(let pane):
            guard containsBackendCanonicalPanel(in: node, tab: tab) else { return nil }
            return UUID(uuidString: pane.id)
        case .split(let split):
            if split.orientation == orientation {
                return positiveEdgeCanonicalPaneID(
                    in: split.second,
                    orientation: orientation,
                    tab: tab
                ) ?? positiveEdgeCanonicalPaneID(
                    in: split.first,
                    orientation: orientation,
                    tab: tab
                )
            }
            return positiveEdgeCanonicalPaneID(
                in: split.first,
                orientation: orientation,
                tab: tab
            ) ?? positiveEdgeCanonicalPaneID(
                in: split.second,
                orientation: orientation,
                tab: tab
            )
        }
    }

    private func containsBackendCanonicalPanel(
        in node: ExternalTreeNode,
        tab: Workspace
    ) -> Bool {
        switch node {
        case .pane(let pane):
            guard let paneUUID = UUID(uuidString: pane.id) else { return false }
            return tab.bonsplitController.tabs(inPane: Bonsplit.PaneID(id: paneUUID)).contains {
                candidate in
                guard let panelID = tab.panelIdFromSurfaceId(candidate.id) else { return false }
                return tab.isBackendCanonicalPanel(panelID)
            }
        case .split(let split):
            return containsBackendCanonicalPanel(in: split.first, tab: tab)
                || containsBackendCanonicalPanel(in: split.second, tab: tab)
        }
    }
}
