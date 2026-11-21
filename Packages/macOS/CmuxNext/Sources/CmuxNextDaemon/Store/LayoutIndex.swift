import Foundation

/// Where each pane and daemon split sits in one screen's tree (``ScreenModel/layout``): the steps from the root
/// (`true` for `b`) to the leaf showing a pane or the stack holding it, and to each split with a daemon handle. The
/// same depth-first order as ``LayoutNode/contains(pane:)`` and the overlay's spot walk, descending only through
/// splits, keeping a pane's first place, so a lookup answers what those walks answer without walking.
///
/// Generic tree plumbing for the optimistic overlay (``OptimisticRules``): no rule reads it. The screen keeps it with
/// its tree (``ScreenModel/layoutIndex()``): built once per tree the daemon writes, edited in place by an overlay's
/// splice and put back with its undo, so an intent's lookups cost the change, not the screen.
struct LayoutIndex {
    private(set) var panes: [PaneID: [Bool]] = [:]
    private(set) var splits: [SplitID: [Bool]] = [:]
    /// False when the tree shows a pane or names a split twice: a lookup could then name the wrong place, so the
    /// screen drops the index and the overlay walks.
    private(set) var exact = true

    init(_ tree: LayoutNode) {
        var path: [Bool] = []
        add(tree, path: &path)
    }

    /// How a new tree differs from the indexed one.
    enum Change {
        /// The same tree.
        case unchanged
        /// The node at `path` (`old`) replaced by `new`, the rest as it was.
        case splice(path: [Bool], old: LayoutNode, new: LayoutNode)
        /// Anything else: the index is built again.
        case other
    }

    /// The steps to the leaf showing `pane` or the stack holding it; nil when the tree does not show it.
    func path(of pane: PaneID) -> [Bool]? { panes[pane] }

    /// The steps to the split under daemon handle `split`; nil when the tree has none.
    func path(of split: SplitID) -> [Bool]? { splits[split] }

    /// Whether the tree shows `pane` (a leaf or in a stack).
    func contains(pane: PaneID) -> Bool { panes[pane] != nil }

    /// The node at `path` in the tree is replaced by `new` (``LayoutNode/splicing(at:with:)`` with a node): drops
    /// what `old` held, adds what `new` holds under `path`. Costs the two subtrees, not the tree.
    mutating func replace(at path: [Bool], old: LayoutNode, new: LayoutNode) {
        remove(old)
        var at = path
        add(new, path: &at)
    }

    private mutating func add(_ node: LayoutNode, path: inout [Bool]) {
        switch node {
        case .leaf(let pane): place(pane, at: path)
        case .stack(let stacked, _): for pane in stacked { place(pane, at: path) }
        case .split(let id, _, _, _, let a, let b):
            if let id {
                if splits[id] == nil { splits[id] = path } else { exact = false }
            }
            path.append(false)
            add(a, path: &path)
            path.removeLast()
            path.append(true)
            add(b, path: &path)
            path.removeLast()
        case .unknown: break
        }
    }

    private mutating func place(_ pane: PaneID, at path: [Bool]) {
        if panes[pane] == nil { panes[pane] = path } else { exact = false }
    }

    private mutating func remove(_ node: LayoutNode) {
        switch node {
        case .leaf(let pane): panes[pane] = nil
        case .stack(let stacked, _): for pane in stacked { panes[pane] = nil }
        case .split(let id, _, _, _, let a, let b):
            if let id { splits[id] = nil }
            remove(a)
            remove(b)
        case .unknown: break
        }
    }
}

extension LayoutNode {
    /// The node at `path` (steps from this node, `true` for `b`, through splits only); nil when the path leaves the tree.
    func node(at path: ArraySlice<Bool>) -> LayoutNode? {
        var node = self
        for step in path {
            guard case .split(_, _, _, _, let a, let b) = node else { return nil }
            node = step ? b : a
        }
        return node
    }
}
