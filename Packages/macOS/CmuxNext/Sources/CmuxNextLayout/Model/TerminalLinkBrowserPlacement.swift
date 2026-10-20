import CoreGraphics

/// Describes where a terminal's default browser link should open.
public nonisolated struct TerminalLinkBrowserPlacement {
    public nonisolated enum Destination: Equatable {
        case reuse(PaneID)
        case split(PaneID)
    }

    public nonisolated init() {}

    /// The pane on `source`'s right where its link's browser tab opens, or nil when none is
    /// there (or `source` is on no screen) and the link takes a new right split.
    @MainActor public func pane(beside source: PaneID, in model: LayoutModel, frames: [PaneID: CGRect]) -> PaneID? {
        guard let screen = model.screen(containing: source),
              case .reuse(let pane) = destination(for: source, in: screen.layout, frames: frames) else { return nil }
        return pane
    }

    /// Chooses an existing pane on the source's right, or a new right split.
    public nonisolated func destination(for source: PaneID, in layout: ScreenLayout, frames: [PaneID: CGRect]) -> Destination {
        guard let sourceFrame = frames[source] else { return .split(source) }
        if let tree = tree(containing: source, in: layout),
           let right = preferredPane(source: source, sourceFrame: sourceFrame, in: tree, frames: frames) {
            return .reuse(right)
        }
        if let right = preferredPaneInNextColumn(source: source, sourceFrame: sourceFrame, in: layout, frames: frames) {
            return .reuse(right)
        }
        return .split(source)
    }

    private func tree(containing source: PaneID, in layout: ScreenLayout) -> SplitNode? {
        switch layout {
        case .splits(let root): root.contains(source) ? root : nil
        case .columns:
            layout.column(containing: source)?.tree(containing: source)
        }
    }

    /// Walks from the source toward the root, so the first usable horizontal
    /// ancestor is the nearest right-side split, matching classic cmux.
    private func preferredPane(source: PaneID, sourceFrame: CGRect, in tree: SplitNode, frames: [PaneID: CGRect]) -> PaneID? {
        guard let path = path(to: source, in: tree) else { return nil }
        for branch in path where branch.axis == .horizontal && branch.sourceIsFirst {
            let candidates = branch.second.panes.filter { $0 != source && frames[$0] != nil }
            if let pane = best(candidates, sourceFrame: sourceFrame, frames: frames) { return pane }
        }
        return nil
    }

    /// Columns are independent split trees. A browser in the next displayed
    /// column is still the existing right-side destination, so consider those
    /// panes before creating another split in the source column.
    private func preferredPaneInNextColumn(
        source: PaneID,
        sourceFrame: CGRect,
        in layout: ScreenLayout,
        frames: [PaneID: CGRect]
    ) -> PaneID? {
        guard case .columns = layout,
              let columns = sourceColumnSequence(in: layout),
              let sourceIndex = columns.firstIndex(where: { $0.root.contains(source) }) else { return nil }
        let epsilon: CGFloat = 1.5
        for column in columns.dropFirst(sourceIndex + 1) {
            let candidates = column.root.panes.filter { pane in
                guard let frame = frames[pane] else { return false }
                return frame.minX >= sourceFrame.maxX - epsilon
            }
            if let pane = best(candidates, sourceFrame: sourceFrame, frames: frames) { return pane }
        }
        return nil
    }

    private func sourceColumnSequence(in layout: ScreenLayout) -> [LayoutColumn]? {
        guard case .columns = layout else { return nil }
        return layout.visualColumns
    }

    private func best(_ candidates: [PaneID], sourceFrame: CGRect, frames: [PaneID: CGRect]) -> PaneID? {
        candidates.sorted { lhs, rhs in
            guard let lhsFrame = frames[lhs], let rhsFrame = frames[rhs] else { return lhs.rawValue < rhs.rawValue }
            let lhsDy = abs(lhsFrame.midY - sourceFrame.midY)
            let rhsDy = abs(rhsFrame.midY - sourceFrame.midY)
            if lhsDy != rhsDy { return lhsDy < rhsDy }
            let lhsDx = abs(lhsFrame.minX - sourceFrame.maxX)
            let rhsDx = abs(rhsFrame.minX - sourceFrame.maxX)
            if lhsDx != rhsDx { return lhsDx < rhsDx }
            if lhsFrame.minX != rhsFrame.minX { return lhsFrame.minX < rhsFrame.minX }
            return lhs.rawValue < rhs.rawValue
        }.first
    }

    private func path(to source: PaneID, in tree: SplitNode) -> [Branch]? {
        switch tree {
        case .leaf(let pane):
            return pane == source ? [] : nil
        case .split(_, let axis, _, let a, let b):
            if var path = path(to: source, in: a) {
                path.append(Branch(axis: axis, sourceIsFirst: true, second: b))
                return path
            }
            if var path = path(to: source, in: b) {
                path.append(Branch(axis: axis, sourceIsFirst: false, second: a))
                return path
            }
            return nil
        }
    }

    private struct Branch {
        let axis: SplitAxis
        let sourceIsFirst: Bool
        let second: SplitNode
    }
}
