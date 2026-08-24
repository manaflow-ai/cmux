#if os(iOS)
import SwiftUI

/// The expanding radar rings behind the connect-stage hero while searching.
///
/// Purely decorative: hidden from accessibility, and the caller omits it
/// entirely under Reduce Motion.
struct WelcomeSearchPulse: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 0.8)
        }
        .onAppear { isAnimating = true }
        .accessibilityHidden(true)
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 2)
            .frame(width: 84, height: 84)
            .scaleEffect(isAnimating ? 1.7 : 1)
            .opacity(isAnimating ? 0 : 0.8)
            .animation(
                .easeOut(duration: 2.0).repeatForever(autoreverses: false).delay(delay),
                value: isAnimating
            )
    }
}
#endif
