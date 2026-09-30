#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingSceneFooter: View {
    let primaryTitle: String?
    let secondaryTitle: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 12) {
                    actions
                }
            } else {
                VStack(spacing: 10) {
                    actions
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.top, verticalSizeClass == .compact ? 8 : 16)
        .padding(.bottom, verticalSizeClass == .compact ? 8 : 12)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingFooter")
    }

    @ViewBuilder
    private var actions: some View {
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

        if secondaryTitle != nil || (primaryTitle != nil && verticalSizeClass != .compact) {
            // Reserve the actual control's size, including system button
            // padding, to keep primary actions aligned across every page.
            // Compact height places actions side by side and needs no slot.
            Button(
                secondaryTitle ?? L10n.string(
                    "mobile.onboarding.push.notNow", defaultValue: "Not Now"
                ),
                action: onSecondary
            )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: verticalSizeClass == .compact ? .infinity : nil)
                .frame(minHeight: 44)
                .opacity(secondaryTitle == nil ? 0 : 1)
                .disabled(secondaryTitle == nil)
                .accessibilityHidden(secondaryTitle == nil)
                .accessibilityIdentifier("MobileOnboardingSecondaryButton")
        }
    }
}
#endif
