import Bonsplit
import SwiftUI

/// One divider strip: a tmux border row/column, drawn as a full separator cell
/// of pane background with a hairline through the middle. Horizontal strips
/// double as header rows for the panes below them.
struct RemoteTmuxDividerStrip: View {
    /// One pane's header info: the x-span it occupies, the y its top edge
    /// sits at (to find the strip directly above it), its tmux-style label
    /// (`index "title"`), and whether it is tmux's active pane.
    struct Segment {
        let paneId: Int
        let xRange: ClosedRange<CGFloat>
        let top: CGFloat
        let label: String
        let isActive: Bool
    }

    let rect: CGRect
    let appearance: PanelAppearance
    let segments: [Segment]
    @Environment(\.displayScale) private var displayScale

    /// Minimum room for the label itself; with the 12pt of margins
    /// subtracted first, labels hide once the pane's visible span drops
    /// below ~52pt — narrower than that they'd collide with a neighbor's.
    private static let minimumLabelWidth: CGFloat = 40

    var body: some View {
        // True hairline, like tmux's box-drawing border glyphs: one DEVICE
        // pixel, not one point (a 2pt bar reads as a slab next to a real
        // tmux client).
        let line = 1 / max(1, displayScale)
        let horizontal = rect.width >= rect.height
        ZStack(alignment: .topLeading) {
            Color(nsColor: appearance.backgroundColor)
            if horizontal {
                appearance.dividerColor
                    .frame(width: rect.width, height: line)
                    .offset(y: (rect.height - line) / 2)
                // This strip is the header row of every pane whose top edge
                // rests on it: render each such pane's title inset on the
                // line, tmux-style (`─ 0 "title" ─`), dot for the active
                // pane. Colors derive from the terminal's own foreground —
                // Color.secondary on a dark terminal is how the old header
                // buttons became invisible.
                ForEach(headerSegmentsOnThisStrip, id: \.paneId) { segment in
                    let visibleStart = max(segment.xRange.lowerBound, rect.minX)
                    let visibleWidth = min(segment.xRange.upperBound, rect.maxX) - visibleStart - 12
                    if segment.isActive || !segment.label.isEmpty,
                       visibleWidth >= Self.minimumLabelWidth {
                        RemoteTmuxStripLabel(
                            label: segment.label, isActive: segment.isActive,
                            appearance: appearance
                        )
                        .frame(maxWidth: visibleWidth, alignment: .leading)
                        .frame(height: rect.height)
                        .offset(x: visibleStart - rect.minX + 6)
                    }
                }
            } else {
                appearance.dividerColor
                    .frame(width: line, height: rect.height)
                    .offset(x: (rect.width - line) / 2)
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }

    /// The panes whose header row this strip is: their top edge rests on the
    /// strip's bottom edge (within a rail-bias tolerance, in points) and
    /// their x-span overlaps it.
    private var headerSegmentsOnThisStrip: [Segment] {
        segments.filter { segment in
            abs(rect.maxY - segment.top) < 2 &&
                segment.xRange.upperBound > rect.minX &&
                segment.xRange.lowerBound < rect.maxX
        }
    }
}
