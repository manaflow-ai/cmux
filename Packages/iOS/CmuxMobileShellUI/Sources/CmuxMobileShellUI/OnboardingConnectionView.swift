#if os(iOS)
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

    // The method choice stays available in every phase, including after a
    // connection is up, so switching to Tailscale or Direct never requires
    // finishing onboarding and digging into Settings. Selecting a method on a
    // live connection is safe: the shared store's change observer replaces the
    // current connection under the newly selected method.
    private var visual: some View {
        ViewThatFits(in: .vertical) {
            connectionVisual(density: .regular)
            connectionVisual(density: .compact)
        }
    }

    @ViewBuilder
    private func connectionVisual(density: OnboardingConnectionVisualDensity) -> some View {
        if verticalSizeClass == .compact {
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
                OnboardingConnectionMethodPicker(
                    method: connectionMethod,
                    density: density,
                    onSelect: onSelectConnectionMethod
                )
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
        if connectionMethod == .direct {
            return L10n.string(
                "mobile.onboarding.connect.directTitle",
                defaultValue: "Connect over a direct address"
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
                Works with cmux 0.64.17 or later. Install Tailscale on both devices and join the same network. \
                On 0.64.17, choose Connect iPhone/iPad and scan the Pair iPhone code once.
                """
            )
        }
        if connectionMethod == .direct {
            return L10n.string(
                "mobile.onboarding.connect.directBody",
                defaultValue: "Dials only the addresses you add for each computer. No relay discovery."
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.body",
            defaultValue: "Use the same cmux account on both devices. Your Mac connects automatically."
        )
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
