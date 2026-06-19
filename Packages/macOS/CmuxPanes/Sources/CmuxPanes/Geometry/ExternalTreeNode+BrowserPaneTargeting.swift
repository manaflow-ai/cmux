public import CoreGraphics
public import Bonsplit

/// Which child of a split a breadcrumb descends into while walking the path to
/// a target pane. Formerly the app-side `Workspace.BrowserPaneBranch`.
public enum BrowserPaneBranch: Sendable, Equatable {
    case first
    case second
}

/// One step on the root-to-pane path through the split tree: the split that was
/// descended and which branch led toward the target. Formerly the app-side
/// `Workspace.BrowserPaneBreadcrumb`. Used by the right-side target-pane picker
/// to find a horizontal split whose first branch holds the source pane.
public struct BrowserPaneBreadcrumb: Sendable, Equatable {
    public let split: ExternalSplitNode
    public let branch: BrowserPaneBranch

    public init(split: ExternalSplitNode, branch: BrowserPaneBranch) {
        self.split = split
        self.branch = branch
    }
}

/// Pure split-tree walks used by the browser/right-sidebar pane-targeting logic,
/// lifted one-for-one from the app-side `Workspace.browserPathToPane`,
/// `Workspace.browserCollectPaneNodes`, and
/// `Workspace.browserCollectNormalizedPaneBounds` recursions. The split tree
/// itself lives in `BonsplitController`; these are read-only computations over a
/// snapshot and carry no app-domain coupling. The app-side pickers
/// (`preferredRightSideTargetPane`, `topRightBrowserReusePane`, nearest-pane
/// resolution) keep their `BonsplitController` reads and frame/sort math and call
/// these for the recursion.
extension ExternalTreeNode {
    /// The breadcrumb path from this subtree's root to the pane with the given
    /// id, leaf-last (the recursion appends as it unwinds, so the deepest split
    /// is first and the root split is last, matching the legacy order). Returns
    /// `nil` when the pane is absent (formerly `Workspace.browserPathToPane`).
    public func browserPathToPane(targetPaneId: String) -> [BrowserPaneBreadcrumb]? {
        switch self {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = splitNode.first.browserPathToPane(targetPaneId: targetPaneId) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .first))
                return path
            }
            if var path = splitNode.second.browserPathToPane(targetPaneId: targetPaneId) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .second))
                return path
            }
            return nil
        }
    }

    /// Appends every pane node in this subtree to `output` in depth-first
    /// first-then-second order (formerly `Workspace.browserCollectPaneNodes`).
    public func browserCollectPaneNodes(into output: inout [ExternalPaneNode]) {
        switch self {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            splitNode.first.browserCollectPaneNodes(into: &output)
            splitNode.second.browserCollectPaneNodes(into: &output)
        }
    }

    /// Maps every pane id to its normalized 0...1 rect within `availableRect`,
    /// splitting the rect by each split's orientation and clamped divider
    /// position (formerly `Workspace.browserCollectNormalizedPaneBounds`).
    /// Vertical splits stack first=top/second=bottom; horizontal splits place
    /// first=left/second=right, matching the legacy geometry exactly.
    public func browserCollectNormalizedPaneBounds(
        availableRect: CGRect,
        into output: inout [String: CGRect]
    ) {
        switch self {
        case .pane(let paneNode):
            output[paneNode.id] = availableRect
        case .split(let splitNode):
            let divider = min(max(splitNode.dividerPosition, 0), 1)
            let firstRect: CGRect
            let secondRect: CGRect

            if splitNode.orientation.lowercased() == "vertical" {
                // Stacked split: first = top, second = bottom
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width,
                    height: availableRect.height * divider
                )
                secondRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY + (availableRect.height * divider),
                    width: availableRect.width,
                    height: availableRect.height * (1 - divider)
                )
            } else {
                // Side-by-side split: first = left, second = right
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width * divider,
                    height: availableRect.height
                )
                secondRect = CGRect(
                    x: availableRect.minX + (availableRect.width * divider),
                    y: availableRect.minY,
                    width: availableRect.width * (1 - divider),
                    height: availableRect.height
                )
            }

            splitNode.first.browserCollectNormalizedPaneBounds(availableRect: firstRect, into: &output)
            splitNode.second.browserCollectNormalizedPaneBounds(availableRect: secondRect, into: &output)
        }
    }
}
