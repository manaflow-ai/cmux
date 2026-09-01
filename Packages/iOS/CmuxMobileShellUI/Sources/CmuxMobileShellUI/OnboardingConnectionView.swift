#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void
    var keepAwakeOffer: OnboardingKeepAwakeOffer?
    var onSetKeepAwake: (Bool) async -> Void = { _ in }
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

    /// The Keep Mac Awake ask takes the decision slot the picker vacated:
    /// it exists only once the Mac is connected and its state is known.
    private var visibleKeepAwakeOffer: OnboardingKeepAwakeOffer? {
        phase == .ready ? keepAwakeOffer : nil
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
                if let visibleKeepAwakeOffer {
                    OnboardingKeepAwakeCard(
                        offer: visibleKeepAwakeOffer,
                        density: density,
                        onSet: onSetKeepAwake
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
        if connectionMethod == .tailscale {
            return L10n.string(
                "mobile.onboarding.connect.tailscaleBody",
                defaultValue: """
                Works with cmux 0.64.17 or later. Install Tailscale on both devices and join the same network. \
                On 0.64.17, choose Connect iPhone/iPad and scan the Pair iPhone code once.
                """
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
