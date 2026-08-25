#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingSceneHeader: View {
    let stage: OnboardingStage
    let showsBack: Bool
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack {
            if showsBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .accessibilityLabel(L10n.string(
                    "mobile.onboarding.back",
                    defaultValue: "Back"
                ))
                .accessibilityIdentifier("MobileOnboardingBackButton")
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }

            Spacer()

            if showsSkip {
                Button(action: onSkip) {
                    Text(L10n.string("mobile.onboarding.skip", defaultValue: "Skip"))
                        .font(.subheadline.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("MobileOnboardingSkipButton")
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            OnboardingProgressIndicator(stage: stage)
                .background {
                    // Washes the animated backdrop cells out behind the page
                    // dots so they never read as extra pages; tracks the
                    // indicator wherever the header lands. Backgrounds do not
                    // affect layout, so the oversized fade is free.
                    EllipticalGradient(
                        colors: [
                            PlatformPalette.systemBackground,
                            PlatformPalette.systemBackground,
                            PlatformPalette.systemBackground.opacity(0),
                        ],
                        center: .center
                    )
                    .frame(width: 220, height: 110)
                }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingHeader")
    }
}
#endif
