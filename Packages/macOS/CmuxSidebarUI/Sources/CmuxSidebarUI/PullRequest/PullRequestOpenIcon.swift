import SwiftUI

/// Custom vector glyph for an open pull request: a branch line feeding a node
/// graph. Drawn at a fixed 13×13 frame; ``PullRequestStatusIcon`` scales it.
struct PullRequestOpenIcon: View {
    let color: Color
    private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
    private static let nodeDiameter: CGFloat = 3.0
    private static let frameSize: CGFloat = 13

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 3.0, y: 4.8))
                path.addLine(to: CGPoint(x: 3.0, y: 9.2))

                path.move(to: CGPoint(x: 4.8, y: 3.0))
                path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                path.addLine(to: CGPoint(x: 11.0, y: 9.2))
            }
            .stroke(color, style: Self.stroke)

            Circle()
                .stroke(color, lineWidth: Self.stroke.lineWidth)
                .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                .position(x: 3.0, y: 3.0)

            Circle()
                .stroke(color, lineWidth: Self.stroke.lineWidth)
                .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                .position(x: 3.0, y: 11.0)

            Circle()
                .stroke(color, lineWidth: Self.stroke.lineWidth)
                .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                .position(x: 11.0, y: 11.0)
        }
        .frame(width: Self.frameSize, height: Self.frameSize)
    }
}
