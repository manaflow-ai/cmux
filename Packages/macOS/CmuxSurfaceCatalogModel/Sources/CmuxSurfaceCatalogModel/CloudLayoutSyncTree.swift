import Foundation

/// The split tree a native Cloud workspace shows, expressed in daemon tab IDs.
///
/// A bound Cloud workspace mirrors one daemon workspace. When the user changes the
/// native arrangement (moves a tab to another pane, splits by drag, reorders tabs or
/// drags a divider), this value is what the machine must be converged to, so that the
/// daemon's layout document stays the durable record of the user's arrangement.
///
/// ```swift
/// let tree = CloudLayoutSyncTree.split(
///     horizontal: true, ratio: 0.6,
///     first: .leaf(tabIDs: ["tab_a", "tab_b"], activeTabID: "tab_b"),
///     second: .leaf(tabIDs: ["tab_c"], activeTabID: nil)
/// )
/// ```
public indirect enum CloudLayoutSyncTree: Hashable, Sendable {
    /// One pane with its tabs in tab-bar order.
    ///
    /// `activeTabID`, when present, is the tab the pane shows and must be one of `tabIDs`.
    case leaf(tabIDs: [String], activeTabID: String?)
    /// Two subtrees side by side (`horizontal`) or stacked, where `ratio` is the
    /// first child's share of the split.
    case split(horizontal: Bool, ratio: Double, first: CloudLayoutSyncTree, second: CloudLayoutSyncTree)

    /// The panes of the tree in document order, first leaf first.
    public var leaves: [(tabIDs: [String], activeTabID: String?)] {
        switch self {
        case .leaf(let tabIDs, let activeTabID):
            return [(tabIDs, activeTabID)]
        case .split(_, _, let first, let second):
            return first.leaves + second.leaves
        }
    }
}
