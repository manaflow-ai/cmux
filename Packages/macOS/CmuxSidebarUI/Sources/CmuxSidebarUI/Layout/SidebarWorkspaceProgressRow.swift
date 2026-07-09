public import CoreGraphics
public import SwiftUI

/// The agent-progress bar shown under a workspace row.
///
/// Renders a capsule track with a leading fill proportional to ``value`` and an
/// optional label beneath it. The track and fill colors are resolved by the
/// caller from the active/inverted-foreground ramp and passed in as values, so
/// this package view carries no app-target color dependency. The bar height is
/// fixed after appear (lazy rows must be height-stable; see the owning row's
/// no-implicit-animation note).
public struct SidebarWorkspaceProgressRow: View {
    let value: Double
    let label: String?
    let trackColor: Color
    let fillColor: Color
    let labelColor: Color
    let fontScale: CGFloat

    /// Creates the progress row.
    /// - Parameters:
    ///   - value: Completion fraction in `0...1`; clamped to the bar width.
    ///   - label: Optional caption shown under the bar.
    ///   - trackColor: Fill color for the unfilled capsule track.
    ///   - fillColor: Fill color for the completed portion.
    ///   - labelColor: Foreground color for the caption.
    ///   - fontScale: Multiplier applied to the bar height and caption size.
    public init(
        value: Double,
        label: String?,
        trackColor: Color,
        fillColor: Color,
        labelColor: Color,
        fontScale: CGFloat
    ) {
        self.value = value
        self.label = label
        self.trackColor = trackColor
        self.fillColor = fillColor
        self.labelColor = labelColor
        self.fontScale = fontScale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(0, geo.size.width * CGFloat(value)))
                }
            }
            .frame(height: max(3, 3 * fontScale))

            if let label {
                Text(label)
                    .font(.system(size: 9 * fontScale))
                    .foregroundColor(labelColor)
                    .lineLimit(1)
            }
        }
    }
}
