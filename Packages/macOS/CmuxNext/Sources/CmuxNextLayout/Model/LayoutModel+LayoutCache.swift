public import CoreGraphics
public import CmuxNextDesign

/// The shown screen's split tree in the layout cache's terms (cmux-layout-cache `PaneNode` and
/// `LiveNode`), and Rust's `reconcile` of a cached tree against it. Values only: no layout runs.
extension LayoutModel {
    /// The cached tree: fractions from the split ratios (a column layout is one horizontal split
    /// by column width; its rows are cached as each column's tree, TODO: rows), each leaf at
    /// `frame(pane)` (content points, top-left origin; zero when the pane is not in a window).
    public func layoutCacheNode(frame: (PaneID) -> CGRect?) -> LayoutCachePaneNode? {
        guard let layout = activeScreen?.layout else { return nil }
        func node(_ split: SplitNode) -> LayoutCachePaneNode {
            switch split {
            case let .leaf(id):
                .leaf(LayoutCacheLeaf(paneId: id.rawValue, kind: .other, frame: LayoutCacheRect(frame(id) ?? .zero)))
            case let .split(_, axis, ratio, a, b):
                .split(horizontal: axis == .horizontal, fractions: [ratio, 1 - ratio], children: [node(a), node(b)])
            }
        }
        switch layout {
        case let .splits(root): return node(root)
        case let .columns(columns):
            let total = columns.reduce(0) { $0 + max(0, $1.width) }
            guard total > 0 else { return nil }
            if columns.count == 1 { return node(columns[0].root) }
            return .split(horizontal: true, fractions: columns.map { max(0, $0.width) / total }, children: columns.map { node($0.root) })
        }
    }

    /// The live tree for `reconcile`: the daemon's structure of the shown screen in `bounds`.
    public func layoutCacheLive(bounds: CGRect?) -> LayoutCacheLiveTree? {
        guard let layout = activeScreen?.layout else { return nil }
        func node(_ split: SplitNode) -> LayoutCacheLiveNode {
            switch split {
            case let .leaf(id): .leaf(paneId: id.rawValue, kind: .other)
            case let .split(_, axis, _, a, b): .split(horizontal: axis == .horizontal, children: [node(a), node(b)])
            }
        }
        let root: LayoutCacheLiveNode? = switch layout {
        case let .splits(split): node(split)
        case let .columns(columns) where columns.isEmpty: nil
        case let .columns(columns): columns.count == 1 ? node(columns[0].root) : .split(horizontal: true, children: columns.map { node($0.root) })
        }
        return LayoutCacheLiveTree(panes: layout.panes.map(\.rawValue), root: root, bounds: bounds.map(LayoutCacheRect.init),
                                   divider: Double(style.dividerThickness))
    }

    /// A launch-timing mark for how `cached` fits the live tree: `layout_cache.exact` when the first
    /// frame was the final frame, else how many panes moved and how many transitions it needed.
    /// Diagnostic for now: the split ratios are the daemon's, and setting them from the cache would
    /// send resize intents that rewrite the person's layout. TODO: give `applied.node`'s leaf frames
    /// to `LayoutRootView` as its first pass's geometry once it takes one, and animate `moved` once.
    public func layoutCacheDrift(cached: LayoutCachePaneNode, bounds: CGRect?) -> String? {
        // Rust writes a default leaf for a window with no tree: nothing was cached to compare.
        if case let .leaf(leaf) = cached, leaf.paneId.isEmpty { return nil }
        guard let live = layoutCacheLive(bounds: bounds), let applied = LayoutCacheFFI.reconcile(cached, live: live) else { return nil }
        return applied.transitions.isEmpty && applied.moved.isEmpty
            ? "layout_cache.exact" : "layout_cache.drift.moved_\(applied.moved.count).transitions_\(applied.transitions.count)"
    }
}
