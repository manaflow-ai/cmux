#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase
    var keepAwakeOffer: OnboardingKeepAwakeOffer?
    var onSetKeepAwake: (Bool) async -> Void = { _ in }
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
                visual: visual,
                bodyLineReservation: 3
            )
        }
    }

    /// The Keep Mac Awake ask appears once the Mac is connected and its state
    /// is known.
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
        if verticalSizeClass == .compact {
            VStack(spacing: density.sectionSpacing) {
                HStack(alignment: .center, spacing: density.sectionSpacing) {
                    OnboardingConnectionPreview(phase: phase, density: density)
                        .frame(maxWidth: .infinity)
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
        } else {
            VStack(spacing: density.sectionSpacing) {
                OnboardingConnectionPreview(phase: phase, density: density)
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
        return L10n.string(
            "mobile.onboarding.connect.title",
            defaultValue: "Your Mac connects automatically"
        )
    }

    private var message: String {
        if phase == .ready {
            let connectedCopy = L10n.string(
                "mobile.onboarding.ready.body",
                defaultValue: "Open any workspace and respond when an agent needs you."
            )
            return "\(connectedCopy) \(MobilePairingCopy().enableOnMacShort)"
        }
        if let requiredMacVersion {
            let connectionCopy = String(
                format: L10n.string(
                    "mobile.onboarding.connect.bodyWithMinVersionFormat",
                    defaultValue: "Use the same cmux account on both devices. Requires cmux %1$@ or newer on your Mac."
                ),
                requiredMacVersion
            )
            return "\(connectionCopy) \(MobilePairingCopy().enableOnMacShort)"
        }
        let connectionCopy = L10n.string(
            "mobile.onboarding.connect.body",
            defaultValue: "Use the same cmux account on both devices. Your Mac connects automatically."
        )
        return "\(connectionCopy) \(MobilePairingCopy().enableOnMacShort)"
    }

    /// The minimum stable-channel Mac version this app version accepts, from
    /// the fetched (or compiled-in) policy tier; `nil` when no tier applies,
    /// which keeps the versionless copy.
    ///
    /// Deliberately the STABLE floor even though Nightly Macs are admitted
    /// under a separate rule: onboarding guides a fresh Mac install, where
    /// the stable download is the default and its floor is the one version a
    /// person can act on. The nightly floor is a build counter, not a
    /// human-typeable version, and this copy is informational — a compatible
    /// Nightly Mac is never blocked by it.
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
