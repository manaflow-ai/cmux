import SwiftUI

/// Fixed-size agent status indicator used by rack strips and tab rows.
struct PaneRackStatusDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
