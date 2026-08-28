#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport

struct OnboardingSceneChrome: Equatable {
    let showsBack: Bool
    let showsSkip: Bool
    let primaryTitle: String?
    let secondaryTitle: String?

    init(
        stage: OnboardingStage,
        isAuthenticated: Bool,
        connectionPhase: OnboardingConnectionPhase,
        connectionMethod: MobileConnectionMethod = .relay
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
        case .push:
            primaryTitle = L10n.string(
                "mobile.onboarding.push.enable",
                defaultValue: "Enable Notifications"
            )
            secondaryTitle = L10n.string(
                "mobile.onboarding.push.notNow",
                defaultValue: "Not Now"
            )
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
                if connectionMethod == .tailscale {
                    primaryTitle = Self.scanPairingCodeTitle
                } else {
                    primaryTitle = L10n.string(
                        "mobile.onboarding.connect.start",
                        defaultValue: "Check for My Mac"
                    )
                }
                secondaryTitle = nil
            case .searching:
                primaryTitle = nil
                secondaryTitle = nil
            case .fallback:
                if connectionMethod == .tailscale {
                    primaryTitle = Self.scanPairingCodeTitle
                    secondaryTitle = L10n.string(
                        "mobile.onboarding.connect.primary",
                        defaultValue: "Check Again"
                    )
                } else {
                    primaryTitle = L10n.string(
                        "mobile.onboarding.connect.primary",
                        defaultValue: "Check Again"
                    )
                    secondaryTitle = nil
                }
            case .ready:
                primaryTitle = L10n.string(
                    "mobile.onboarding.ready.primary",
                    defaultValue: "Open Workspaces"
                )
                secondaryTitle = nil
            }
        }
    }

    private static var scanPairingCodeTitle: String {
        L10n.string(
            "mobile.onboarding.connect.scanTailscaleCode",
            defaultValue: "Scan Pairing Code"
        )
    }
}
#endif
