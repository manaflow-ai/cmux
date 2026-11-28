#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Introduces the durable notification feed with a capture of its production UI.
struct OnboardingNotificationsView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingNotificationsScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.notifications.body",
                    defaultValue: "Review every agent alert in one feed."
                ),
                visual: OnboardingScreenshot(
                    content: .notifications,
                    accessibilityLabel: title
                )
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.notifications.title",
            defaultValue: "Every agent alert, in one place"
        )
    }
}
#endif
