public import Foundation

/// Structural view of a persisted workspace layout node, used by the
/// package-owned prune algorithm without importing the app's concrete
/// snapshot DTO graph.
///
/// A layout tree is either a leaf pane carrying an ordered panel-id list and
/// a selected panel, or a split carrying a divider position and two child
/// subtrees of the same conforming `Node` type. The associated values stay
/// `Node` so the package never needs a twin of the app's pane/split structs:
/// it reads the shape, decides what survives, and asks the conformer to
/// rebuild the same concrete type.
public enum SessionLayoutPruneCase<Node: Sendable>: Sendable {
    /// A leaf pane: the panel ids it hosts and the selected panel.
    case pane(panelIds: [UUID], selectedPanelId: UUID?, isFullWidthTabMode: Bool?)
    /// A split: its divider position and the two child subtrees.
    case split(dividerPosition: Double, first: Node, second: Node)
}

/// Seam satisfied by the app's `SessionWorkspaceLayoutSnapshot` enum so the
/// package can prune a persisted layout tree down to a surviving set of
/// panel ids while keeping the wire format (and the concrete DTOs) owned by
/// the app target.
///
/// The conformer destructures itself into a ``SessionLayoutPruneCase`` and
/// supplies two reconstructors. The package never constructs a pane or split
/// payload directly: it filters/reselects panel ids for a pane and rebuilds
/// a split from already-pruned children, byte-faithfully reproducing the
/// legacy in-file `prunedSessionLayoutSnapshot` behavior.
public protocol SessionLayoutPruning: Sendable {
    /// Destructures this node into a structural prune case.
    var sessionLayoutPruneCase: SessionLayoutPruneCase<Self> { get }

    /// Rebuilds a leaf pane node from a surviving panel-id list and selection.
    static func sessionLayoutPrunedPane(
        panelIds: [UUID],
        selectedPanelId: UUID?,
        isFullWidthTabMode: Bool?
    ) -> Self

    /// Rebuilds a split node from its divider position and pruned children,
    /// preserving the original split's orientation (carried by the conformer).
    func sessionLayoutPrunedSplit(dividerPosition: Double, first: Self, second: Self) -> Self
}

extension SessionLayoutPruning {
    /// Prunes the layout tree to the panels in `panelIdsToKeep`, dropping
    /// empty panes and collapsing splits whose children collapse, exactly as
    /// the legacy `Workspace.prunedSessionLayoutSnapshot(_:keeping:)` did.
    public func sessionLayoutPruned(keeping panelIdsToKeep: Set<UUID>) -> Self? {
        switch sessionLayoutPruneCase {
        case let .pane(panelIds, selectedPanelId, isFullWidthTabMode):
            let survivingPanelIds = panelIds.filter { panelIdsToKeep.contains($0) }
            guard !survivingPanelIds.isEmpty else { return nil }
            let resolvedSelectedPanelId = selectedPanelId.flatMap {
                panelIdsToKeep.contains($0) ? $0 : nil
            } ?? survivingPanelIds.first
            return Self.sessionLayoutPrunedPane(
                panelIds: survivingPanelIds,
                selectedPanelId: resolvedSelectedPanelId,
                isFullWidthTabMode: isFullWidthTabMode
            )
        case let .split(dividerPosition, first, second):
            let prunedFirst = first.sessionLayoutPruned(keeping: panelIdsToKeep)
            let prunedSecond = second.sessionLayoutPruned(keeping: panelIdsToKeep)
            switch (prunedFirst, prunedSecond) {
            case let (.some(prunedFirst), .some(prunedSecond)):
                return sessionLayoutPrunedSplit(
                    dividerPosition: dividerPosition,
                    first: prunedFirst,
                    second: prunedSecond
                )
            case let (.some(prunedFirst), .none):
                return prunedFirst
            case let (.none, .some(prunedSecond)):
                return prunedSecond
            case (.none, .none):
                return nil
            }
        }
    }
}
