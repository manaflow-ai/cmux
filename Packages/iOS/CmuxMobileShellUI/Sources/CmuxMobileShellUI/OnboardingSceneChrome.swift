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
        showsSkip = stage != .connect

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
        case .connect:
            guard isAuthenticated else {
                primaryTitle = nil
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
                secondaryTitle = L10n.string(
                    "mobile.onboarding.connect.fallback",
                    defaultValue: "Use QR Code Instead"
                )
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
