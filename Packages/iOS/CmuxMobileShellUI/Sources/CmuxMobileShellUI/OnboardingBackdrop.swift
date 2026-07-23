#if os(iOS)
import SwiftUI

struct OnboardingBackdrop: View {
    var body: some View {
        PlatformPalette.systemBackground
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
#endif
