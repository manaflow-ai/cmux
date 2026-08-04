import SwiftUI

/// Lawrence's fixed upright Sky-kite cursor from Austin's cmux-cua work.
struct SimulatorAgentCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 18.59
        let scaleY = rect.height / 18.59
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scaleX, y: rect.minY + y * scaleY)
        }

        var path = Path()
        path.move(to: point(3.68, 4.83))
        path.addLine(to: point(6.63, 12.78))
        path.addQuadCurve(
            to: point(8.30, 12.66),
            control: point(7.67, 15.59)
        )
        path.addLine(to: point(8.44, 12.01))
        path.addQuadCurve(
            to: point(12.01, 8.44),
            control: point(9.08, 9.08)
        )
        path.addLine(to: point(12.66, 8.30))
        path.addQuadCurve(
            to: point(12.78, 6.63),
            control: point(15.59, 7.67)
        )
        path.addLine(to: point(4.83, 3.68))
        path.addQuadCurve(
            to: point(3.68, 4.83),
            control: point(3.00, 3.00)
        )
        path.closeSubpath()
        return path
    }
}
