#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Shows a real Lock Screen capture of a cmux agent notification with its
/// inline reply typed out, before the footer's Enable button triggers the
/// one-time system permission alert. The OS is never asked before this page
/// (HIG: show the value of a permission before requesting it).
struct OnboardingPushView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingPushScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.push.body",
                    defaultValue: "Get a push when an agent is waiting, and reply right from the Lock Screen."
                ),
                visual: OnboardingScreenshot(
                    content: .push,
                    accessibilityLabel: title
                )
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.push.title",
            defaultValue: "Know the moment an agent needs you"
        )
    }
}
#endif
