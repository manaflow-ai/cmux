import Foundation
import SwiftUI

/// Activity pulse that fades from full opacity to its quarter-opacity rest state.
struct PaneRackPulseDot: View {
    let color: Color
    let lastActivityAt: Date?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .phaseAnimator([false, true], trigger: lastActivityAt) { content, isResting in
                content.opacity(isResting ? 0.25 : 1)
            } animation: { isResting in
                isResting ? .easeOut(duration: 0.7) : .linear(duration: 0)
            }
            .accessibilityHidden(true)
    }
}
