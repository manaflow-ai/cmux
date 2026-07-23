#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingConnectScene")

            OnboardingSceneContent(
                title: title,
                message: message,
                visual: OnboardingScreenshot(
                    content: .terminal,
                    accessibilityLabel: title
                )
            )
        }
    }

    private var title: String {
        if phase == .ready {
            return L10n.string(
                "mobile.onboarding.ready.title",
                defaultValue: "Your Mac is connected"
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.title",
            defaultValue: "Your Mac connects automatically"
        )
    }

    private var message: String {
        if phase == .ready {
            return L10n.string(
                "mobile.onboarding.ready.body",
                defaultValue: "Open a workspace to see the latest activity and respond when an agent needs you."
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.body",
            defaultValue: "Keep cmux open on your Mac and sign in with the same account. cmux finds it and connects securely."
        )
    }
}
#endif
