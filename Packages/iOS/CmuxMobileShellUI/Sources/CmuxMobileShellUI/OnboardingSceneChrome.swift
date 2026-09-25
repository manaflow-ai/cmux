#if os(iOS)
import CmuxMobileSupport

struct OnboardingSceneChrome: Equatable {
    let showsBack: Bool
    let showsSkip: Bool
    let primaryTitle: String?
    let secondaryTitle: String?

    init(
        stage: OnboardingStage,
        isAuthenticated: Bool,
        connectionPhase: OnboardingConnectionPhase
    ) {
        showsBack = stage != .agents
        // Pairing opt-in is the required handoff between the tour and Mac
        // discovery. Keep it from reading like an incidental permission.
        showsSkip = stage != .connect && stage != .pairing

        switch stage {
        case .agents:
            primaryTitle = L10n.string(
                "mobile.onboarding.agents.primary",
                defaultValue: "Continue"
            )
            secondaryTitle = nil
        case .notifications:
            primaryTitle = L10n.string(
                "mobile.onboarding.continue",
                defaultValue: "Continue"
            )
            secondaryTitle = nil
        case .push:
            primaryTitle = L10n.string(
                "mobile.onboarding.push.enable",
                defaultValue: "Enable Notifications"
            )
            secondaryTitle = L10n.string(
                "mobile.onboarding.push.notNow",
                defaultValue: "Not Now"
            )
        case .pairing:
            primaryTitle = L10n.string(
                "mobile.onboarding.pairing.primary",
                defaultValue: "I've enabled iOS pairing"
            )
            secondaryTitle = nil
        case .connect:
            guard isAuthenticated else {
                primaryTitle = L10n.string(
                    "mobile.onboarding.continue",
                    defaultValue: "Continue"
                )
                secondaryTitle = nil
                return
            }

            switch connectionPhase {
            case .idle:
                primaryTitle = L10n.string(
                    "mobile.onboarding.connect.start",
                    defaultValue: "Check for My Mac"
                )
                secondaryTitle = nil
            case .searching:
                primaryTitle = nil
                secondaryTitle = nil
            case .fallback:
                primaryTitle = L10n.string(
                    "mobile.onboarding.connect.primary",
                    defaultValue: "Check Again"
                )
                secondaryTitle = nil
            case .ready:
                primaryTitle = L10n.string(
                    "mobile.onboarding.ready.primary",
                    defaultValue: "Open Workspaces"
                )
                secondaryTitle = nil
            }
        }
    }
}
#endif
