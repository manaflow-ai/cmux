#if os(iOS)
import SwiftUI

struct OnboardingSignInBridgeView: View {
    var body: some View {
        SignInView(usesStandaloneChrome: false)
            .accessibilityIdentifier("MobileOnboardingSignInBridge")
    }
}
#endif
