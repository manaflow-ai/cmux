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
    /// - Returns: What happened.
    @discardableResult
    public func equalize(screen id: ScreenID, viewportWidth: CGFloat?) -> EqualizeResult {
        guard let screen = screens.first(where: { $0.id == id }) else { return .nothingToEqualize }
        let trees: [SplitNode] = switch screen.layout {
        case .splits(let root): [root]
        case .columns(let columns): columns.flatMap(\.trees)
        }
        var values: [DividerDragValue] = []
        var hasSplits = false
        for tree in trees {
            for split in tree.splits {
                hasSplits = true
                if let ratio = tree.equalizedRatio(for: split), let current = tree.ratio(of: split), abs(current - ratio) > 1e-6 {
                    values.append(.ratio(split, ratio))
                }
            }
        }
        var hasColumns = false
        if !screen.zoomed, case .columns(let columns) = screen.layout {
            let style = style
            let visibleColumns = Set(columns.filter { $0.root.panes.contains(where: visiblePanes.contains) }.map(\.id))
            let equalizer = ColumnEqualizer(columns: columns, visible: visibleColumns, viewportWidth: viewportWidth ?? 0,
                                            gap: style.stripGap) { $0.minimumSize(style: style).width }
            let shared = DockStripGeometry.docks(columns)
            hasColumns = shared.scrolling.filter { $0.dock == nil }.count
                + [shared.left, shared.right].compactMap { $0 }.filter { $0.dock?.mode == .docked }.count > 1
            values += equalizer.resizes.map { .width($0.column, $0.width) }
        }
        guard hasSplits || hasColumns else { return .nothingToEqualize }
        guard !values.isEmpty else { return .equalized }
        let change = EndedValues(values)
        guard change.canSend(in: self) else { return .refused }
        explicitReflowUntil = ProcessInfo.processInfo.systemUptime + Self.explicitReflowWindow
        return change.send(in: self) ? .equalized : .refused
    }

    /// Equalizes the same-axis chain holding `split` (a divider's double-click): every cell of that chain, on both sides
    /// of the divider and above or below it in the tree, gets an equal share (``EvenSplitRatios/changes(equalizingChainOf:in:)``).
    /// Setting only `split`'s own ratio assumed every nested same-axis split was even already, so a chain with one
    /// dragged split stayed uneven (#57175). The ratios go out as one change (one undo step). An explicit equalize
    /// springs (`explicitReflowUntil`); the sizing that follows a split or a close moves with that gesture instead.
    public func equalizeSplit(_ split: SplitID) {
        guard let tree = screens.lazy.compactMap({ $0.layout.tree(containing: split) }).first else { return }
        let changes = EvenSplitRatios.changes(equalizingChainOf: split, in: tree)
        guard !changes.isEmpty else { return }
        let change = EndedValues(changes.map { .ratio($0.split, $0.ratio) })
        guard change.canSend(in: self) else { return }
        explicitReflowUntil = ProcessInfo.processInfo.systemUptime + Self.explicitReflowWindow
        change.send(in: self)
    }
}
