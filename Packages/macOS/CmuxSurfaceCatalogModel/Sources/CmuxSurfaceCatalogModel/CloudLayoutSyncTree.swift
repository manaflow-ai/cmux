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

    /// Whether two trees show the same arrangement. Ratios within `ratioTolerance`
    /// are equal: native dividers round to pixels on every resize.
    ///
    /// - Parameters:
    ///   - other: The tree to compare with.
    ///   - ratioTolerance: The largest ratio difference still treated as equal.
    /// - Returns: True when shape, directions, tab order and selection match.
    public func isEquivalent(to other: CloudLayoutSyncTree, ratioTolerance: Double = 0.005) -> Bool {
        switch (self, other) {
        case let (.leaf(tabs, active), .leaf(otherTabs, otherActive)):
            return tabs == otherTabs && active == otherActive
        case let (.split(horizontal, ratio, first, second), .split(otherHorizontal, otherRatio, otherFirst, otherSecond)):
            return horizontal == otherHorizontal && abs(ratio - otherRatio) <= ratioTolerance
                && first.isEquivalent(to: otherFirst, ratioTolerance: ratioTolerance)
                && second.isEquivalent(to: otherSecond, ratioTolerance: ratioTolerance)
        default:
            return false
        }
    }

    /// The tree restricted to `tabIDs`; a pane left empty collapses into its sibling.
    func keeping(_ tabIDs: Set<String>) -> CloudLayoutSyncTree? {
        switch self {
        case .leaf(let tabs, let active):
            let kept = tabs.filter(tabIDs.contains)
            guard !kept.isEmpty else { return nil }
            return .leaf(tabIDs: kept, activeTabID: active.flatMap { kept.contains($0) ? $0 : nil })
        case .split(let horizontal, let ratio, let first, let second):
            switch (first.keeping(tabIDs), second.keeping(tabIDs)) {
            case let (first?, second?): return .split(horizontal: horizontal, ratio: ratio, first: first, second: second)
            case let (only?, nil), let (nil, only?): return only
            case (nil, nil): return nil
            }
        }
    }

    /// The tree with `tabID` placed next to `anchor`, after it or before it.
    func inserting(_ tabID: String, beside anchor: String, after: Bool) -> CloudLayoutSyncTree {
        switch self {
        case .leaf(var tabs, let active):
            guard let index = tabs.firstIndex(of: anchor) else { return self }
            tabs.insert(tabID, at: after ? index + 1 : index)
            return .leaf(tabIDs: tabs, activeTabID: active)
        case .split(let horizontal, let ratio, let first, let second):
            return .split(horizontal: horizontal, ratio: ratio,
                          first: first.inserting(tabID, beside: anchor, after: after),
                          second: second.inserting(tabID, beside: anchor, after: after))
        }
    }
}
