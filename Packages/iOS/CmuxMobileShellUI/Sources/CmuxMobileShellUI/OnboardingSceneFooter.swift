#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingSceneFooter: View {
    let primaryTitle: String?
    let secondaryTitle: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let primaryTitle {
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                }
                .mobileGlassProminentButton()
                .accessibilityIdentifier("MobileOnboardingPrimaryButton")
            }

            if let secondaryTitle {
                Button(secondaryTitle, action: onSecondary)
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 36)
                    .accessibilityIdentifier("MobileOnboardingSecondaryButton")
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}
#endif
