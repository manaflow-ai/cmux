#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void
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

    /// The method choice stays visible while there is still a decision to act
    /// on; once connected it disappears (Settings keeps the control).
    private var showsMethodPicker: Bool {
        phase == .idle || phase == .fallback
    }

    private var visual: some View {
        ViewThatFits(in: .vertical) {
            connectionVisual(density: .regular)
            connectionVisual(density: .compact)
        }
    }

    @ViewBuilder
    private func connectionVisual(density: OnboardingConnectionVisualDensity) -> some View {
        if verticalSizeClass == .compact, showsMethodPicker {
            HStack(alignment: .center, spacing: density.sectionSpacing) {
                OnboardingConnectionPreview(phase: phase, density: density)
                    .frame(maxWidth: .infinity)
                OnboardingConnectionMethodPicker(
                    method: connectionMethod,
                    density: density,
                    onSelect: onSelectConnectionMethod
                )
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: density.sectionSpacing) {
                OnboardingConnectionPreview(phase: phase, density: density)
                if showsMethodPicker {
                    OnboardingConnectionMethodPicker(
                        method: connectionMethod,
                        density: density,
                        onSelect: onSelectConnectionMethod
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
        if connectionMethod == .tailscale {
            return L10n.string(
                "mobile.onboarding.connect.tailscaleTitle",
                defaultValue: "Connect over Tailscale"
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
                defaultValue: "Open any workspace and respond when an agent needs you."
            )
        }
        // The floor sentence is composed in, not baked into each body, so
        // every connect surface names the same minimum Mac version from
        // MobileMacPairingFloor and the cut-time edit stays one value.
        if connectionMethod == .tailscale {
            return [
                MobileMacPairingFloor.requiredOnMacSentence,
                L10n.string(
                    "mobile.onboarding.connect.tailscaleSteps",
                    defaultValue: """
                    Install Tailscale on both devices and join the same network, \
                    then open Tailscale Pairing on the Mac and scan its code once.
                    """
                ),
            ].joined(separator: " ")
        }
        return [
            L10n.string(
                "mobile.onboarding.connect.body",
                defaultValue: "Use the same cmux account on both devices. Your Mac connects automatically."
            ),
            MobileMacPairingFloor.requiredOnMacSentence,
        ].joined(separator: " ")
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
