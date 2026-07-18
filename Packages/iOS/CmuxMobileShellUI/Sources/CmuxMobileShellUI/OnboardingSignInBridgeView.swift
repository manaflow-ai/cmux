#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingSignInBridgeView: View {
    let onBack: () -> Void

    var body: some View {
        SignInView()
            .overlay(alignment: .topLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(.circle)
                }
                .accessibilityLabel(L10n.string(
                    "mobile.onboarding.back",
                    defaultValue: "Back"
                ))
                .accessibilityIdentifier("MobileOnboardingBackButton")
                .padding(.leading, 16)
                .padding(.top, 4)
            }
    }
}
#endif
