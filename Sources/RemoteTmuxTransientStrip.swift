import Bonsplit
import CmuxRemoteWorkspace
import SwiftUI

/// A transient divider strip matching ``RemoteTmuxDividerStrip`` while panes
/// are still being divided proportionally.
struct RemoteTmuxTransientStrip: View {
    struct Segment {
        let paneId: Int
        let startFraction: CGFloat
        let endFraction: CGFloat
        let label: String
        let isActive: Bool
    }

    let axis: Axis // of the strip itself: horizontal = a row strip
    let segments: [Segment]
    let appearance: PanelAppearance
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let line = 1 / max(1, displayScale)
            ZStack(alignment: .topLeading) {
                Color(nsColor: appearance.backgroundColor)
                if axis == .horizontal {
                    appearance.dividerColor
                        .frame(width: proxy.size.width, height: line)
                        .offset(y: (proxy.size.height - line) / 2)
                    ForEach(segments, id: \.paneId) { segment in
                        let start = segment.startFraction * proxy.size.width
                        let width = (segment.endFraction - segment.startFraction) * proxy.size.width - 12
                        if segment.isActive || !segment.label.isEmpty, width >= 40 {
                            RemoteTmuxStripLabel(
                                label: segment.label, isActive: segment.isActive,
                                appearance: appearance
                            )
                            .frame(maxWidth: width, alignment: .leading)
                            .frame(height: proxy.size.height)
                            .offset(x: start + 6)
                        }
                    }
                } else {
                    appearance.dividerColor
                        .frame(width: line, height: proxy.size.height)
                        .offset(x: (proxy.size.width - line) / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }

    /// The header segments for the strip ABOVE `subtree`: its top-edge panes
    /// (the ones whose tmux title row that strip is), x-spans as fractions of
    /// `root`'s width. Uses the leaves' REAL tmux columns, so segment spans
    /// track the same proportions the split layout divides by.
    @MainActor
    static func topEdgeSegments(
        of subtree: RemoteTmuxLayoutNode,
        within root: RemoteTmuxLayoutNode,
        mirror: RemoteTmuxWindowMirror
    ) -> [Segment] {
        let rootWidth = CGFloat(max(1, root.width))
        var minY = Int.max
        var leaves: [(id: Int, x: Int, width: Int, y: Int)] = []
        func walk(_ n: RemoteTmuxLayoutNode) {
            switch n.content {
            case let .pane(id):
                leaves.append((id, n.x, n.width, n.y))
                minY = min(minY, n.y)
            case let .horizontal(children), let .vertical(children):
                children.forEach(walk)
            }
        }
        walk(subtree)
        return leaves.filter { $0.y == minY }.map { leaf in
            Segment(
                paneId: leaf.id,
                startFraction: CGFloat(max(0, leaf.x)) / rootWidth,
                endFraction: CGFloat(max(0, leaf.x) + leaf.width) / rootWidth,
                label: mirror.tmuxTitleRowsVisible ? (mirror.paneHeaderLabels[leaf.id] ?? "") : "",
                isActive: mirror.activePaneId == leaf.id
            )
        }
    }
}
