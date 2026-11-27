import Foundation
public import CoreGraphics

/// Equalize Splits (Ctrl-Cmd-=, menu, palette, CLI `pane equalize-splits`): one shared path for every entrypoint.
extension LayoutModel {
    /// What ``equalize(screen:viewportWidth:)`` did.
    public enum EqualizeResult: Equatable, Sendable {
        /// The screen has neither a split nor two columns side by side: nothing to equalize.
        case nothingToEqualize
        /// The changed ratios and widths went out as one change (none when all were equal already).
        case equalized
        /// The app could not send them now (a pane the daemon has not made yet): nothing changed.
        case refused
    }

    /// Gives every split on `screen` even ratios and, on a columns screen, every column the window shows side by side
    /// the same width, a docked side dock (Home's Chief chat) included (``ColumnEqualizer``). The change is one
    /// transaction (one undo step) and springs unless motion is off (`explicitReflowUntil`).
    /// - Parameters:
    ///   - id: The screen to equalize.
    ///   - viewportWidth: The screen's width in points; nil keeps every dock's width (only strip columns equalize).
    ///   - geometry: The screen as laid out; with it each chain's shares are sized for its container
    ///     (``evenChanges(_:geometry:style:)``), else leaf counts.
    /// - Returns: What happened.
    @discardableResult
    public func equalize(screen id: ScreenID, viewportWidth: CGFloat?, geometry: ScreenGeometry? = nil) -> EqualizeResult {
        guard let screen = screens.first(where: { $0.id == id }) else { return .nothingToEqualize }
        var widths: [DividerDragValue] = []
        var hasColumns = false
        if !screen.zoomed, case .columns(let columns) = screen.layout {
            let style = style
            let visibleColumns = Set(columns.filter { $0.root.panes.contains(where: visiblePanes.contains) }.map(\.id))
            let equalizer = ColumnEqualizer(columns: columns, visible: visibleColumns, viewportWidth: viewportWidth ?? 0,
                                            gap: style.stripGap) { $0.minimumSize(style: style).width }
            let shared = DockStripGeometry.docks(columns)
            hasColumns = shared.scrolling.filter { $0.dock == nil }.count
                + [shared.left, shared.right].compactMap { $0 }.filter { $0.dock?.mode == .docked }.count > 1
            widths = equalizer.resizes.map { .width($0.column, $0.width) }
        }
        // A column this change widens or narrows lays its rows of panes out in another width than `geometry` shows:
        // its horizontal chains even by leaf counts.
        let resized = Set(widths.compactMap { value -> ColumnID? in
            guard case let .width(column, _) = value else { return nil }
            return column
        })
        let trees: [(tree: SplitNode, resized: Bool)] = switch screen.layout {
        case .splits(let root): [(root, false)]
        case .columns(let columns): columns.flatMap { column in column.trees.map { ($0, resized.contains(column.id)) } }
        }
        var values: [DividerDragValue] = []
        var hasSplits = false
        let splitStyle = style
        for (tree, resized) in trees {
            hasSplits = hasSplits || !tree.splits.isEmpty
            for top in Self.chainTops(tree) {
                var sized = geometry
                if resized, case .split(_, .horizontal, _, _, _) = top { sized = nil }
                values += Self.evenChanges(top, geometry: sized, style: splitStyle).map { .ratio($0.split, $0.ratio) }
            }
        }
        values += widths
        guard hasSplits || hasColumns else { return .nothingToEqualize }
        guard !values.isEmpty else { return .equalized }
        let change = EndedValues(values)
        guard change.canSend(in: self) else { return .refused }
        explicitReflowUntil = ProcessInfo.processInfo.systemUptime + Self.explicitReflowWindow
        return change.send(in: self) ? .equalized : .refused
    }

    /// Equalizes the same-axis chain holding `split` (a divider's double-click): every cell of that chain, on both sides
    /// of the divider and above or below it in the tree, gets an equal share (``EvenSplitRatios``). Setting only
    /// `split`'s own ratio assumed every nested same-axis split was even already, so a chain with one dragged split
    /// stayed uneven (#57175). With `geometry` (the screen as laid out) the shares are sized for the chain's container,
    /// so a cell whose panes need more than an even share keeps its minimum and the other cells still end equal
    /// (``EvenSplitRatios/changes(equalizing:extent:style:)``); without it, leaf counts. The ratios go out as one change
    /// (one undo step). An explicit equalize springs (`explicitReflowUntil`); the sizing that follows a split or a close
    /// moves with that gesture instead.
    public func equalizeSplit(_ split: SplitID, geometry: ScreenGeometry? = nil) {
        guard let tree = screens.lazy.compactMap({ $0.layout.tree(containing: split) }).first,
              let top = EvenSplitRatios.chainTop(of: split, in: tree) else { return }
        send(Self.evenChanges(top, geometry: geometry, style: style))
    }

    /// The changes that even the chain under `top`: sized for its container in `geometry` when it has one there.
    static func evenChanges(_ top: SplitNode, geometry: ScreenGeometry?, style: LayoutStyle) -> [SplitRatioChange] {
        guard case let .split(id, axis, _, _, _) = top else { return [] }
        if let container = geometry?.dividers.first(where: { $0.id == id })?.container {
            return EvenSplitRatios.changes(equalizing: top, extent: container.size.extent(along: axis), style: style)
        }
        return EvenSplitRatios.changes(equalizing: top, axis: axis)
    }

    /// The top split of every same-axis chain in `tree` (the root, and each split whose parent splits across).
    static func chainTops(_ tree: SplitNode) -> [SplitNode] {
        func walk(_ node: SplitNode, parent: SplitAxis?, into tops: inout [SplitNode]) {
            guard case let .split(_, axis, _, a, b) = node else { return }
            if axis != parent { tops.append(node) }
            walk(a, parent: axis, into: &tops)
            walk(b, parent: axis, into: &tops)
        }
        var tops: [SplitNode] = []
        walk(tree, parent: nil, into: &tops)
        return tops
    }

    private func send(_ changes: [SplitRatioChange]) {
        guard !changes.isEmpty else { return }
        let change = EndedValues(changes.map { .ratio($0.split, $0.ratio) })
        guard change.canSend(in: self) else { return }
        explicitReflowUntil = ProcessInfo.processInfo.systemUptime + Self.explicitReflowWindow
        change.send(in: self)
    }
}
