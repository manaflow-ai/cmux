public import SwiftUI
public import CmuxSubrouter

/// A tiny line graph of a usage window's recorded samples (0–100%),
/// tinted by the latest severity. Renders nothing with fewer than two
/// samples — a single point is not a trend.
public struct SubrouterSparklineView: View {
    private let samples: [SubrouterUsageHistory.Sample]

    /// Creates the sparkline.
    /// - Parameter samples: The series, oldest first.
    public init(samples: [SubrouterUsageHistory.Sample]) {
        self.samples = samples
    }

    public var body: some View {
        if samples.count >= 2 {
            GeometryReader { proxy in
                let points = normalizedPoints(in: proxy.size)
                ZStack {
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                        for point in points {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.12))
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 46, height: 14)
            .accessibilityHidden(true)
        }
    }

    private var color: Color {
        let latest = samples.last?.usedPercent ?? 0
        if latest >= 90 { return .red }
        if latest >= 70 { return .yellow }
        return .green
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        let denominator = max(1, samples.count - 1)
        return samples.enumerated().map { index, sample in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(denominator),
                y: size.height * (1 - CGFloat(min(max(sample.usedPercent, 0), 100)) / 100)
            )
        }
    }
}
