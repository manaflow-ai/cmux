#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingHandoffView: View {
    let onBack: () -> Void
    let onSkip: () -> Void
    let onRespond: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingSceneContainer(
            stage: .handoff,
            title: L10n.string(
                "mobile.onboarding.handoff.title",
                defaultValue: "Answer agents from your phone"
            ),
            message: L10n.string(
                "mobile.onboarding.handoff.body",
                defaultValue: "Choose an answer when an agent needs a decision. It keeps working on your Mac."
            ),
            primaryTitle: L10n.string(
                "mobile.onboarding.handoff.primaryContinue",
                defaultValue: "Continue"
            ),
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
}
#endif
