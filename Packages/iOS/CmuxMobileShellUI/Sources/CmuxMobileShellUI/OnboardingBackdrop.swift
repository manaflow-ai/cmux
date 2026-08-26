#if os(iOS)
import SwiftUI

struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            PlatformPalette.systemBackground

            GameOfLifeHeader()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
#endif
