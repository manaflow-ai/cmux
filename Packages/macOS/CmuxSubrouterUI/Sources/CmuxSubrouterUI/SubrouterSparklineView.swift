public import SwiftUI
public import CmuxSubrouter

/// A tiny line graph of a usage window's recorded samples (0–100%),
/// tinted by the latest severity. Renders nothing unless the series
/// shows an actual trend: a single point is not one, and a flat series
/// draws as a bare horizontal stroke that reads as a stray bar next to
/// the percent (the gauge below already shows the level).
public struct SubrouterSparklineView: View {
    private let samples: [SubrouterUsageHistory.Sample]

    /// The minimum spread (in percent points) between the series' low and
    /// high before the line carries information the gauge doesn't.
    private static let minimumTrendSpread = 1.0

    /// Creates the sparkline.
    /// - Parameter samples: The series, oldest first.
    public init(samples: [SubrouterUsageHistory.Sample]) {
        self.samples = samples
    }

    /// Whether the series is worth drawing (see the type comment).
    static func showsTrend(_ samples: [SubrouterUsageHistory.Sample]) -> Bool {
        guard samples.count >= 2,
              let low = samples.map(\.usedPercent).min(),
              let high = samples.map(\.usedPercent).max() else {
            return false
        }
        return high - low >= minimumTrendSpread
    }

    public var body: some View {
        if Self.showsTrend(samples) {
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
        SubrouterPalette.usageAccent(for: samples.last?.usedPercent ?? 0)
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
