#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport

/// Per-stage header and footer configuration. Every step is skippable: the
/// header Skip advances past welcome and connect, and the push stage carries
/// its own "Not Now" secondary instead of a second dismissal in the header.
struct OnboardingSceneChrome: Equatable {
    let showsBack: Bool
    let showsSkip: Bool
    let primaryTitle: String?
    let secondaryTitle: String?

    init(
        stage: OnboardingStage,
        connectionPhase: OnboardingConnectionPhase,
        connectionMethod: MobileConnectionMethod = .automatic
    ) {
        showsBack = stage != .welcome

        switch stage {
        case .welcome:
            showsSkip = true
            primaryTitle = L10n.string(
                "mobile.onboarding.welcome.primary",
                defaultValue: "Get Started"
            )
            secondaryTitle = nil
        case .connect:
            showsSkip = connectionPhase != .ready

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
                    secondaryTitle = Self.checkAgainTitle
                } else {
                    primaryTitle = Self.checkAgainTitle
                    secondaryTitle = Self.scanPairingCodeTitle
                }
            case .ready:
                primaryTitle = L10n.string(
                    "mobile.onboarding.continue",
                    defaultValue: "Continue"
                )
                secondaryTitle = nil
            }
        case .push:
            showsSkip = false
            primaryTitle = L10n.string(
                "mobile.onboarding.push.primary",
                defaultValue: "Enable Notifications"
            )
            secondaryTitle = L10n.string(
                "mobile.onboarding.push.secondary",
                defaultValue: "Not Now"
            )
        }
    }

    private static var scanPairingCodeTitle: String {
        L10n.string(
            "mobile.onboarding.connect.scanTailscaleCode",
            defaultValue: "Scan Pairing Code"
        )
    }

    private static var checkAgainTitle: String {
        L10n.string(
            "mobile.onboarding.connect.primary",
            defaultValue: "Check Again"
        )
    }
}
#endif
