#if os(iOS)
import SwiftUI

/// An iMessage-style received-message bubble with its tail at the
/// bottom-leading corner.
///
/// Drawn as one continuous path so the same shape can be stroked for quoted
/// messages and filled for replies. The body starts ``tailWidth`` points in
/// from the leading edge; the tail hooks out into that gutter and curls back
/// into the bottom edge, matching Messages. Callers add ``tailWidth`` to
/// their leading content padding.
struct AgentFeedBubbleShape: Shape {
    static let tailWidth: CGFloat = 4
    var cornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + Self.tailWidth
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        let radius = min(cornerRadius, rect.height / 2, (right - left) / 2)
        // Bezier handle for a circular-looking corner (8/20 in the classic
        // Messages bubble geometry).
        let handle = radius * 0.4
        let tailTop = max(top + radius, bottom - 11)

        var path = Path()
        path.move(to: CGPoint(x: left + 21, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: right, y: bottom - radius),
            control1: CGPoint(x: right - handle, y: bottom),
            control2: CGPoint(x: right, y: bottom - handle)
        )
        path.addLine(to: CGPoint(x: right, y: top + radius))
        path.addCurve(
            to: CGPoint(x: right - radius, y: top),
            control1: CGPoint(x: right, y: top + handle),
            control2: CGPoint(x: right - handle, y: top)
        )
        path.addLine(to: CGPoint(x: left + radius, y: top))
        path.addCurve(
            to: CGPoint(x: left, y: top + radius),
            control1: CGPoint(x: left + handle, y: top),
            control2: CGPoint(x: left, y: top + handle)
        )
        path.addLine(to: CGPoint(x: left, y: tailTop))
        // Tail: down and out to the tip, then curl back into the bottom edge.
        path.addCurve(
            to: CGPoint(x: rect.minX, y: bottom),
            control1: CGPoint(x: left, y: bottom - 1),
            control2: CGPoint(x: rect.minX, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: left + 7, y: bottom - 4),
            control1: CGPoint(x: rect.minX + 4, y: bottom + 0.5),
            control2: CGPoint(x: left + 4, y: bottom - 1)
        )
        path.addCurve(
            to: CGPoint(x: left + 21, y: bottom),
            control1: CGPoint(x: left + 12, y: bottom),
            control2: CGPoint(x: left + 16, y: bottom)
        )
        path.closeSubpath()
        return path
    }
}
#endif
