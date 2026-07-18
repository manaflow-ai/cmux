#if DEBUG
import SwiftUI

/// Renders the Phosphor eight-point status signal, including the needs-you pulse.
struct PhosphorStatusDot: View {
    let state: GalleryAgentState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulseIsBright = false

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        Circle()
            .fill(theme.statusColor(state))
            .frame(width: 8, height: 8)
            .opacity(theme.isNeedsYou(state) && !reduceMotion ? (pulseIsBright ? 1.0 : 0.6) : 1.0)
            .onAppear {
                guard theme.isNeedsYou(state), !reduceMotion else {
                    pulseIsBright = true
                    return
                }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseIsBright = true
                }
            }
            .accessibilityHidden(true)
    }
}
#endif
