#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let isMacReady: Bool
    let onBack: () -> Void
    let onPrimary: () -> Void
    let onHelp: () -> Void

    var body: some View {
        OnboardingSceneContainer(
            stage: .connect,
            title: title,
            message: message,
            primaryTitle: primaryTitle,
            secondaryTitle: isMacReady ? nil : L10n.string(
                "mobile.onboarding.connect.help",
                defaultValue: "Having trouble connecting?"
            ),
            showsBack: true,
            showsSkip: false,
            onBack: onBack,
            onSkip: {},
            onPrimary: onPrimary,
            onSecondary: onHelp,
            visual: OnboardingConnectionPreview(isReady: isMacReady)
        )
    }

    private var title: String {
        if isMacReady {
            return L10n.string(
                "mobile.onboarding.ready.title",
                defaultValue: "Your Mac is connected"
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.title",
            defaultValue: "Connect your Mac"
        )
    }

    private var message: String {
        if isMacReady {
            return L10n.string(
                "mobile.onboarding.ready.body",
                defaultValue: "Open a workspace to see the latest activity and respond when an agent needs you."
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.body",
            defaultValue: "On your Mac, open cmux and choose Pair iPhone. Then scan the code."
        )
    }

    private var primaryTitle: String {
        if isMacReady {
            return L10n.string(
                "mobile.onboarding.ready.primary",
                defaultValue: "Open Workspaces"
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.primary",
            defaultValue: "Scan Mac QR"
        )
    }
}
#endif
