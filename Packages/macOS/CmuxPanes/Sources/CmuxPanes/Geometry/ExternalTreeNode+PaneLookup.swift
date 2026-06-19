public import Foundation
public import Bonsplit

/// Pure pane-membership lookups over Bonsplit's external snapshot, lifted
/// one-for-one from the app-side `Workspace.splitTreeContainsPane` /
/// `Workspace.splitIdJoiningPaneIds` recursions. The split tree itself lives
/// in `BonsplitController`; these are read-only computations over a snapshot
/// and carry no app-domain coupling.
extension ExternalTreeNode {
    /// Whether the subtree rooted at `self` contains a pane with the given id
    /// (formerly `Workspace.splitTreeContainsPane(_:in:)`).
    public func containsPane(_ paneId: String) -> Bool {
        switch self {
        case .pane(let pane):
            return pane.id == paneId
        case .split(let split):
            return split.first.containsPane(paneId)
                || split.second.containsPane(paneId)
        }
    }

    /// The id of the lowest split that directly separates the two panes: the
    /// nearest split whose two children each contain exactly one of the panes
    /// (formerly `Workspace.splitIdJoiningPaneIds(_:_:in:)`). Returns `nil`
    /// when either pane is absent or the split id fails to parse as a UUID,
    /// matching the legacy behavior exactly.
    public func splitIdJoiningPanes(_ firstPaneId: String, _ secondPaneId: String) -> UUID? {
        switch self {
        case .pane:
            return nil
        case .split(let splitNode):
            let firstContainsFirst = splitNode.first.containsPane(firstPaneId)
            let firstContainsSecond = splitNode.first.containsPane(secondPaneId)
            let secondContainsFirst = splitNode.second.containsPane(firstPaneId)
            let secondContainsSecond = splitNode.second.containsPane(secondPaneId)
            if (firstContainsFirst && secondContainsSecond) || (firstContainsSecond && secondContainsFirst) {
                return UUID(uuidString: splitNode.id)
            }
            return splitNode.first.splitIdJoiningPanes(firstPaneId, secondPaneId)
                ?? splitNode.second.splitIdJoiningPanes(firstPaneId, secondPaneId)
        }
    }
}
