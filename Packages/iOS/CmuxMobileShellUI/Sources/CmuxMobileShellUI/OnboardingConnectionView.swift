#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void
    let onStartTailscalePairing: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingConnectScene")

            OnboardingSceneContent(
                title: title,
                message: message,
                visual: visual
            )
        }
    }

    /// The transport introduction stays visible while there is still a
    /// decision to act on; once connected it disappears (Settings keeps the
    /// full controls).
    private var showsMechanisms: Bool {
        phase != .ready
    }

    private var visual: some View {
        ViewThatFits(in: .vertical) {
            connectionVisual(density: .regular)
            connectionVisual(density: .compact)
        }
    }

    @ViewBuilder
    private func connectionVisual(density: OnboardingConnectionVisualDensity) -> some View {
        if verticalSizeClass == .compact, showsMechanisms {
            HStack(alignment: .center, spacing: density.sectionSpacing) {
                OnboardingConnectionPreview(phase: phase, density: density)
                    .frame(maxWidth: .infinity)
                OnboardingConnectionMechanismsView(
                    method: connectionMethod,
                    density: density,
                    condensed: true,
                    onSelect: onSelectConnectionMethod,
                    onStartTailscalePairing: onStartTailscalePairing
                )
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: density.sectionSpacing) {
                OnboardingConnectionPreview(phase: phase, density: density)
                if showsMechanisms {
                    OnboardingConnectionMechanismsView(
                        method: connectionMethod,
                        density: density,
                        condensed: false,
                        onSelect: onSelectConnectionMethod,
                        onStartTailscalePairing: onStartTailscalePairing
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
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
            defaultValue: "Connect your Mac"
        )
    }

    private var message: String {
        switch phase {
        case .ready:
            return L10n.string(
                "mobile.onboarding.ready.body",
                defaultValue: "Open any workspace and respond when an agent needs you."
            )
        case .fallback:
            if connectionMethod == .tailscale {
                return L10n.string(
                    "mobile.onboarding.connect.tailscaleBody",
                    defaultValue: "Install Tailscale on both devices, then scan the pairing code shown in cmux on your Mac."
                )
            }
            return L10n.string(
                "mobile.onboarding.connect.fallbackBody",
                defaultValue: "No Mac yet. Get cmux at cmux.com and sign in with this same account."
            )
        case .idle, .searching:
            return L10n.string(
                "mobile.onboarding.connect.body",
                defaultValue: "Use the same cmux account on both devices. Your Mac connects automatically."
            )
        }
    }
}

enum OnboardingConnectionVisualDensity {
    case regular
    case compact

    var sectionSpacing: CGFloat {
        switch self {
        case .regular: 14
        case .compact: 8
        }
    }
}
#endif
