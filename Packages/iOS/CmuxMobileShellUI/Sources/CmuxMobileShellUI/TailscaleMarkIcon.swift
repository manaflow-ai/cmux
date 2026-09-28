#if os(iOS)
import SwiftUI

/// The Tailscale logomark: a 3×3 dot grid with the bottom row highlighted.
/// Drawn instead of bundled so it renders in the row's own tint and scales
/// with Dynamic Type like an SF Symbol.
struct TailscaleMarkIcon: View {
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 4.6
    @ScaledMetric(relativeTo: .body) private var gap: CGFloat = 1.9

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: dot, height: dot)
                    }
                }
                .opacity(row == 2 ? 1 : 0.35)
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
