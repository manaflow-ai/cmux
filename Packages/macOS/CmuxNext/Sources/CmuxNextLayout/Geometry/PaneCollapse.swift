public import CoreGraphics

/// The collapsed panes of one laid-out screen (`LayoutStyle.collapsesPanes(along:)`; Lawrence 2026-10-28: a pane
/// thinner than one cell is "a collapsed bar ... that expands on click or a shortcut"). A split's side is collapsed
/// when the layout gave it less than its minimum (``DividerGeometry/minimumA``): dragged or stepped to the edge, or
/// in a window too small for it. Expanding one gives the split its equal share again (`LayoutModel.equalizeSplit`).
public nonisolated struct PaneCollapse: Sendable {
    public let layout: ScreenLayout
    public let dividers: [DividerGeometry]

    /// - Parameters:
    ///   - layout: The screen's layout.
    ///   - dividers: Its laid-out dividers (`ScreenGeometry.dividers`).
    public init(layout: ScreenLayout, dividers: [DividerGeometry]) {
        self.layout = layout
        self.dividers = dividers
    }

    /// The splits with a collapsed side, in layout order; with `pane`, only those whose collapsed side holds it.
    public func collapsedSplits(holding pane: PaneID? = nil) -> [SplitID] {
        dividers.compactMap { divider in
            let horizontal = divider.axis == .horizontal
            let container = divider.container, line = divider.frame
            let sideA = horizontal ? line.minX - container.minX : line.minY - container.minY
            let sideB = horizontal ? container.maxX - line.maxX : container.maxY - line.maxY
            let collapsesA = sideA < divider.minimumA - 0.5, collapsesB = sideB < divider.minimumB - 0.5
            guard collapsesA || collapsesB else { return nil }
            guard let pane else { return divider.id }
            guard let node = layout.tree(containing: divider.id)?.node(for: divider.id) else { return nil }
            return (collapsesA && node.a.contains(pane)) || (collapsesB && node.b.contains(pane)) ? divider.id : nil
        }
    }
}
