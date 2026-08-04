#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void

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
        VStack(spacing: 14) {
            OnboardingConnectionPreview(phase: phase)
            if showsMethodPicker {
                OnboardingConnectionMethodPicker(
                    method: connectionMethod,
                    onSelect: onSelectConnectionMethod
                )
            }
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
        if connectionMethod == .tailscale {
            return L10n.string(
                "mobile.onboarding.connect.tailscaleBody",
                defaultValue: """
                Install Tailscale on this iPhone and your Mac, then connect both to the same Tailscale network. \
                On your Mac, open Tailscale Pairing in cmux to show the QR, then scan it here.
                """
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.body",
            defaultValue: "Use the same cmux account on both devices. Your Mac connects automatically."
        )
    }
}
#endif
