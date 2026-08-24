#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Introduces the three ways the iPhone reaches the Mac on the onboarding
/// connect page: Iroh auto-connect, direct on the local network, and Tailscale
/// (a private network that is itself a direct path). Auto-Connect and
/// Tailscale are selectable and persist through the shared connection-method
/// store, so the Settings picker shows the same value afterward. Direct is
/// informational: both selectable methods upgrade to a direct link on their
/// own, so there is nothing to choose.
struct OnboardingConnectionMechanismsView: View {
    let method: MobileConnectionMethod
    let density: OnboardingConnectionVisualDensity
    /// Compact height (landscape) shows title-only rows so all three
    /// transports stay inside the page viewport; portrait always keeps the
    /// one-line detail, whichever density fits.
    let condensed: Bool
    let onSelect: (MobileConnectionMethod) -> Void
    let onStartTailscalePairing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: density.mechanismOptionSpacing) {
            Text(L10n.string(
                "mobile.onboarding.connect.mechanisms.header",
                defaultValue: "How your iPhone reaches your Mac"
            ))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            selectableCard(
                .automatic,
                title: L10n.string(
                    "mobile.onboarding.connect.mechanism.iroh",
                    defaultValue: "Auto-Connect"
                ),
                subtitle: L10n.string(
                    "mobile.onboarding.connect.mechanism.irohDetail",
                    defaultValue: "Works anywhere. Encrypted relays find your Mac, then traffic moves peer to peer when the network allows."
                ),
                systemImage: "bolt.fill",
                accessibilityIdentifier: "MobileOnboardingMechanismAutomatic"
            )

            infoCard(
                title: L10n.string(
                    "mobile.onboarding.connect.mechanism.direct",
                    defaultValue: "Direct"
                ),
                subtitle: L10n.string(
                    "mobile.onboarding.connect.mechanism.directDetail",
                    defaultValue: "On the same Wi-Fi or LAN, the connection upgrades to a direct local link on its own."
                ),
                badge: L10n.string(
                    "mobile.onboarding.connect.mechanism.directBadge",
                    defaultValue: "Automatic"
                ),
                systemImage: "wifi",
                accessibilityIdentifier: "MobileOnboardingMechanismDirect"
            )

            selectableCard(
                .tailscale,
                title: L10n.string(
                    "mobile.onboarding.connect.mechanism.tailscale",
                    defaultValue: "Tailscale"
                ),
                subtitle: L10n.string(
                    "mobile.onboarding.connect.mechanism.tailscaleDetail",
                    defaultValue: "Already on a tailnet? That is a private direct network. Scan the pairing code on your Mac once."
                ),
                systemImage: "network.badge.shield.half.filled",
                accessibilityIdentifier: "MobileOnboardingMechanismTailscale"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingConnectionMechanisms")
    }

    private func selectableCard(
        _ option: MobileConnectionMethod,
        title: String,
        subtitle: String,
        systemImage: String,
        accessibilityIdentifier: String
    ) -> some View {
        let isSelected = method == option
        return Button {
            if option == .tailscale, !isSelected {
                onSelect(option)
                onStartTailscalePairing()
            } else {
                onSelect(option)
            }
        } label: {
            cardLabel(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconTint: isSelected ? Color.accentColor : Color.secondary
            ) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: density.mechanismCornerRadius, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func infoCard(
        title: String,
        subtitle: String,
        badge: String,
        systemImage: String,
        accessibilityIdentifier: String
    ) -> some View {
        cardLabel(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            iconTint: .secondary
        ) {
            Text(badge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .overlay {
            RoundedRectangle(cornerRadius: density.mechanismCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func cardLabel(
        title: String,
        subtitle: String,
        systemImage: String,
        iconTint: Color,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: density.mechanismRowSpacing) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(iconTint)
                .frame(width: density.mechanismIconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !condensed {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, density.mechanismHorizontalPadding)
        .padding(.vertical, density.mechanismVerticalPadding)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: density.mechanismCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

private extension OnboardingConnectionVisualDensity {
    var mechanismOptionSpacing: CGFloat {
        switch self {
        case .regular: 10
        case .compact: 4
        }
    }

    var mechanismRowSpacing: CGFloat {
        switch self {
        case .regular: 12
        case .compact: 6
        }
    }

    var mechanismIconWidth: CGFloat {
        switch self {
        case .regular: 26
        case .compact: 20
        }
    }

    var mechanismHorizontalPadding: CGFloat {
        switch self {
        case .regular: 16
        case .compact: 10
        }
    }

    var mechanismVerticalPadding: CGFloat {
        switch self {
        case .regular: 12
        case .compact: 6
        }
    }

    var mechanismCornerRadius: CGFloat {
        switch self {
        case .regular: 16
        case .compact: 14
        }
    }
}
#endif
