#if os(iOS)
import SwiftUI

/// An iMessage-style message bubble with a tail at its bottom-leading corner.
///
/// Drawn as one continuous path so the same shape can be stroked for quoted
/// messages and filled for replies. The tail tip extends
/// ``tailOverhang`` points left of the bubble's frame; callers add that much
/// leading padding so the tip stays inside their layout.
struct AgentFeedBubbleShape: Shape {
    static let tailOverhang: CGFloat = 5
    var cornerRadius: CGFloat = 17

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        let tailJoinY = max(rect.minY + radius, rect.maxY - 11)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        // Tail: the bottom edge sweeps out to a tip past the leading edge,
        // then curves back up into it.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX - Self.tailOverhang, y: rect.maxY),
            control: CGPoint(x: rect.minX + 2, y: rect.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: tailJoinY),
            control: CGPoint(x: rect.minX + 1, y: rect.maxY - 3)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
#endif
