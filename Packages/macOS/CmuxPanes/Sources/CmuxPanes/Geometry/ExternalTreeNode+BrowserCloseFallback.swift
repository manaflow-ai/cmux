public import Bonsplit
public import Foundation

/// Where a browser pane should re-open after its closing neighbor is gone: the
/// split orientation to recreate, which side of that split the restored pane
/// takes, and the surviving pane it anchors against. Formerly the app-side
/// private `Workspace.BrowserCloseFallbackPlan`.
///
/// `anchorPaneId` is the surviving pane geometrically nearest the closed pane's
/// center; `insertFirst` records whether the closed pane was the first (left/top)
/// branch of the split that joined it to its sibling, so the restore can rebuild
/// the same orientation and side.
public struct BrowserCloseFallbackPlan: Sendable, Equatable {
    public let orientation: SplitOrientation
    public let insertFirst: Bool
    public let anchorPaneId: UUID?

    public init(orientation: SplitOrientation, insertFirst: Bool, anchorPaneId: UUID?) {
        self.orientation = orientation
        self.insertFirst = insertFirst
        self.anchorPaneId = anchorPaneId
    }
}

/// Pure split-tree walks that compute how to re-open a closed browser pane,
/// lifted one-for-one from the app-side `Workspace.browserCloseFallbackPlan`,
/// `Workspace.browserPaneCenter`, and `Workspace.browserNearestPaneId`
/// recursions. The split tree itself lives in `BonsplitController`; these are
/// read-only computations over a snapshot and carry no app-domain coupling. The
/// app-side `stageClosedBrowserRestoreSnapshotIfNeeded` keeps its
/// `BonsplitController`/panel reads and calls `browserCloseFallbackPlan(forPaneId:)`
/// for the recursion.
extension ExternalTreeNode {
    /// The fallback plan for re-opening the pane with the given id once it
    /// closes: finds the split that directly pairs the target pane with a
    /// sibling subtree, records the orientation and which branch the target
    /// held, and resolves the nearest surviving pane in the sibling subtree as
    /// the anchor. Returns `nil` when the pane is not a direct child of any
    /// split (formerly `Workspace.browserCloseFallbackPlan(forPaneId:in:)`).
    public func browserCloseFallbackPlan(forPaneId targetPaneId: String) -> BrowserCloseFallbackPlan? {
        switch self {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first, firstPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: true,
                    anchorPaneId: splitNode.second.browserNearestPaneId(
                        targetCenter: firstPane.browserPaneCenter
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second, secondPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: false,
                    anchorPaneId: splitNode.first.browserNearestPaneId(
                        targetCenter: secondPane.browserPaneCenter
                    )
                )
            }

            if let nested = splitNode.first.browserCloseFallbackPlan(forPaneId: targetPaneId) {
                return nested
            }
            return splitNode.second.browserCloseFallbackPlan(forPaneId: targetPaneId)
        }
    }

    /// The pane in this subtree whose center is geometrically nearest
    /// `targetCenter` (squared-distance, with the pane id as a stable tie-break),
    /// or the first pane in depth-first order when `targetCenter` is `nil`.
    /// Returns `nil` for an empty subtree or when the chosen pane id fails to
    /// parse as a UUID (formerly `Workspace.browserNearestPaneId(in:targetCenter:)`).
    public func browserNearestPaneId(targetCenter: (x: Double, y: Double)?) -> UUID? {
        var panes: [ExternalPaneNode] = []
        browserCollectPaneNodes(into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = lhs.browserPaneCenter
                let rhsCenter = rhs.browserPaneCenter
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2) + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2) + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        guard let bestPane else { return nil }
        return UUID(uuidString: bestPane.id)
    }
}

extension ExternalPaneNode {
    /// The center point of this pane's frame in the snapshot's coordinate space
    /// (formerly `Workspace.browserPaneCenter(_:)`).
    public var browserPaneCenter: (x: Double, y: Double) {
        (
            x: frame.x + (frame.width * 0.5),
            y: frame.y + (frame.height * 0.5)
        )
    }
}
