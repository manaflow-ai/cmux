import CmuxNextLayout
import CoreGraphics

/// Describes where a terminal's default browser link should open.
struct TerminalLinkBrowserPlacement {
    enum Destination: Equatable {
        case reuse(PaneID)
        case split(PaneID)
    }

    /// Chooses an existing pane on the source's right, or a new right split.
    func destination(for source: PaneID, in layout: ScreenLayout, frames: [PaneID: CGRect]) -> Destination {
        guard let tree = tree(containing: source, in: layout),
              let right = preferredPane(source: source, in: tree, frames: frames) else {
            return .split(source)
        }
        return .reuse(right)
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
    private func preferredPane(source: PaneID, in tree: SplitNode, frames: [PaneID: CGRect]) -> PaneID? {
        guard let path = path(to: source, in: tree) else { return nil }
        let sourceFrame = frames[source]
        let sourceCenterY = sourceFrame?.midY ?? 0
        let sourceRightX = sourceFrame?.maxX ?? 0

        for branch in path where branch.axis == .horizontal && branch.sourceIsFirst {
            let candidates = branch.second.panes.filter { $0 != source }
            if candidates.isEmpty { continue }
            return candidates.sorted { lhs, rhs in
                guard let lhsFrame = frames[lhs], let rhsFrame = frames[rhs], sourceFrame != nil else {
                    return lhs.rawValue < rhs.rawValue
                }
                let lhsDy = abs(lhsFrame.midY - sourceCenterY)
                let rhsDy = abs(rhsFrame.midY - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }
                let lhsDx = abs(lhsFrame.minX - sourceRightX)
                let rhsDx = abs(rhsFrame.minX - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }
                if lhsFrame.minX != rhsFrame.minX { return lhsFrame.minX < rhsFrame.minX }
                return lhs.rawValue < rhs.rawValue
            }.first
        }
        return nil
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
