#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingAgentsView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingAgentsScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.agents.body",
                    defaultValue: "See every workspace and its latest activity, wherever you are."
                ),
                visual: OnboardingWorkspacePreview()
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.agents.title",
            defaultValue: "Your agents keep working on your Mac"
        )
    }
}
#endif
