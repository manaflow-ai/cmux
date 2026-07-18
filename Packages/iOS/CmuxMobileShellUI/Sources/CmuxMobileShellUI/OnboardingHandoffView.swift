#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingHandoffView: View {
    let isMacReady: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onRespond: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingSceneContainer(
            stage: .handoff,
            title: L10n.string(
                "mobile.onboarding.handoff.title",
                defaultValue: "Step in when they need you"
            ),
            message: L10n.string(
                "mobile.onboarding.handoff.body",
                defaultValue: "Answer a question, approve a command, or send a message from your phone."
            ),
            primaryTitle: primaryTitle,
            secondaryTitle: nil,
            showsBack: true,
            showsSkip: true,
            onBack: onBack,
            onSkip: onSkip,
            onPrimary: onContinue,
            onSecondary: {},
            visual: OnboardingAgentHandoffPreview(onRespond: onRespond)
        )
    }

    private var primaryTitle: String {
        if isMacReady {
            return L10n.string(
                "mobile.onboarding.handoff.primaryContinue",
                defaultValue: "Continue"
            )
        }
        return L10n.string(
            "mobile.onboarding.handoff.primaryConnect",
            defaultValue: "Connect my Mac"
        )
    }
}
#endif
