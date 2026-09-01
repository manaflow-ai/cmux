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
    /// Names the minimum Mac version for this app version in the connect
    /// copy. Optional so previews without the app root keep versionless copy.
    @Environment(MobileMacCompatCenter.self) private var macCompatCenter:
        MobileMacCompatCenter?

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
        if connectionMethod == .tailscale {
            if let requiredMacVersion {
                return String(
                    format: L10n.string(
                        "mobile.onboarding.connect.tailscaleBodyWithMinVersionFormat",
                        defaultValue: "Requires cmux %1$@ or newer on your Mac. Install Tailscale on both devices and join the same network, then scan the pairing code once."
                    ),
                    requiredMacVersion
                )
            }
            // Versionless fallback (below-tier app versions, previews): no
            // stale hardcoded floor; the policy-driven branch above names one.
            return L10n.string(
                "mobile.onboarding.connect.tailscaleBody",
                defaultValue: "Install Tailscale on both devices and join the same network, then scan the pairing code once."
            )
        }
        if let requiredMacVersion {
            return String(
                format: L10n.string(
                    "mobile.onboarding.connect.bodyWithMinVersionFormat",
                    defaultValue: "Use the same cmux account on both devices. Requires cmux %1$@ or newer on your Mac."
                ),
                requiredMacVersion
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.body",
            defaultValue: "Use the same cmux account on both devices. Your Mac connects automatically."
        )
    }

    /// The minimum stable-channel Mac version this app version accepts, from
    /// the fetched (or compiled-in) policy tier; `nil` when no tier applies,
    /// which keeps the versionless copy.
    private var requiredMacVersion: String? {
        macCompatCenter?.policy
            .tier(forIOSVersion: AppVersionInfo.current().marketingVersion)?
            .stableMinVersion.description
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
