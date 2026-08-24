#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Pitches push notifications with an in-app mock of a real cmux banner and
/// its inline reply, before the OS permission prompt. The mock needs no
/// authorization, so people see exactly what they are opting into first.
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
                    defaultValue: "Get pinged when an agent finishes or wants approval, and reply right from the notification."
                ),
                visual: OnboardingPushPreview()
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
