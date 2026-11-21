import Foundation

// MARK: Generic tree walks (no rule here: find, contains, last pane, splice)

extension LayoutNode {
    /// Whether `pane` is one of this tree's panes. Walks without allocating, unlike ``paneIDs``.
    func contains(pane: PaneID) -> Bool {
        switch self {
        case .leaf(let leaf): leaf == pane
        case .split(_, _, _, _, let a, let b): a.contains(pane: pane) || b.contains(pane: pane)
        case .stack(let panes, _): panes.contains(pane)
        case .unknown: false
        }
    }

    /// The last pane: a split's second side's, a stack's expanded pane.
    var lastPane: PaneID? {
        switch self {
        case .leaf(let pane): pane
        case .split(_, _, _, _, _, let b): b.lastPane
        case .stack(_, let expanded): expanded
        case .unknown: nil
        }
    }

    /// Adds every pane of the tree to `panes`.
    func collectPanes(into panes: inout Set<PaneID>) {
        switch self {
        case .leaf(let pane): panes.insert(pane)
        case .split(_, _, _, _, let a, let b):
            a.collectPanes(into: &panes)
            b.collectPanes(into: &panes)
        case .stack(let stacked, _): panes.formUnion(stacked)
        case .unknown: break
        }
    }

    /// The first node, depth first, `a` before `b`, descending only through splits, that `match` matches;
    /// `path` ends as its steps from the root (`true` for `b`).
    func find(_ match: OptimisticRules.Match, path: inout [Bool]) -> LayoutNode? {
        if match.matches(self) { return self }
        guard case .split(_, _, _, _, let a, let b) = self else { return nil }
        path.append(false)
        if let found = a.find(match, path: &path) { return found }
        path.removeLast()
        path.append(true)
        if let found = b.find(match, path: &path) { return found }
        path.removeLast()
        return nil
    }

    /// The tree with the node at `path` replaced by `new`, rebuilding only the path. A nil `new` takes the node
    /// out and its parent split becomes its other side, as it is; nil when that leaves no tree.
    func splicing(at path: ArraySlice<Bool>, with new: LayoutNode?) -> LayoutNode? {
        guard let step = path.first, case .split(let id, let resourceID, let direction, let ratio, let a, let b) = self else { return new }
        guard let child = (step ? b : a).splicing(at: path.dropFirst(), with: new) else { return step ? a : b }
        return .split(id: id, resourceID: resourceID, direction: direction, ratio: ratio, a: step ? a : child, b: step ? child : b)
    }
}
