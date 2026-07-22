#if os(iOS)
import SwiftUI

struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            PlatformPalette.systemBackground

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.16),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 420
            )

            RadialGradient(
                colors: [
                    Color.indigo.opacity(colorScheme == .dark ? 0.18 : 0.09),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
#endif
