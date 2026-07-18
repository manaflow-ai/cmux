#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingAgentsView: View {
    let onSkip: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingSceneContainer(
            stage: .agents,
            title: L10n.string(
                "mobile.onboarding.agents.title",
                defaultValue: "Your agents keep working on your Mac"
            ),
            message: L10n.string(
                "mobile.onboarding.agents.body",
                defaultValue: "See every workspace and its latest activity, wherever you are."
            ),
            primaryTitle: L10n.string(
                "mobile.onboarding.agents.primary",
                defaultValue: "Continue"
            ),
            secondaryTitle: nil,
            showsBack: false,
            showsSkip: true,
            onBack: {},
            onSkip: onSkip,
            onPrimary: onContinue,
            onSecondary: {},
            visual: OnboardingWorkspacePreview()
        )
    }
}
#endif
