#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Introduces the durable notification-feed contract without reproducing its UI.
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
                    defaultValue: "The Notifications feed keeps every agent alert from your paired Macs in chronological order, even when push alerts are off. Tap one to open its workspace."
                ),
                visual: OnboardingNotificationPreview()
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
