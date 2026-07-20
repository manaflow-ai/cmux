#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase
    let onBack: () -> Void
    let onPrimary: () -> Void
    let onFallback: () -> Void

    var body: some View {
        OnboardingSceneContainer(
            stage: .connect,
            title: title,
            message: message,
            primaryTitle: primaryTitle,
            secondaryTitle: secondaryTitle,
            showsBack: true,
            showsSkip: false,
            onBack: onBack,
            onSkip: {},
            onPrimary: onPrimary,
            onSecondary: onFallback,
            showsContent: true,
            visual: OnboardingConnectionPreview(phase: phase)
        )
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

    private var primaryTitle: String? {
        switch phase {
        case .searching:
            nil
        case .fallback:
            L10n.string(
                "mobile.onboarding.connect.primary",
                defaultValue: "Check Again"
            )
        case .ready:
            L10n.string(
                "mobile.onboarding.ready.primary",
                defaultValue: "Open Workspaces"
            )
        }
    }

    private var secondaryTitle: String? {
        guard phase == .fallback else { return nil }
        return L10n.string(
            "mobile.onboarding.connect.fallback",
            defaultValue: "Use QR Code Instead"
        )
    }
}
#endif
