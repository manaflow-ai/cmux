#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The connection-method choice on the onboarding connect page. Selection
/// persists through the shared connection-method store, so the Settings
/// picker shows the same value afterward.
struct OnboardingConnectionMethodPicker: View {
    let method: MobileConnectionMethod
    let density: OnboardingConnectionVisualDensity
    let onSelect: (MobileConnectionMethod) -> Void

    /// Every connection method is offered during onboarding, in the same
    /// order as the per-Computer picker in Settings.
    static let offeredMethods: [MobileConnectionMethod] = [.automatic, .tailscale, .direct]

    var body: some View {
        VStack(spacing: density.pickerOptionSpacing) {
            ForEach(Self.offeredMethods, id: \.self) { option in
                optionCard(option)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingConnectionMethodPicker")
    }

    private static func title(for option: MobileConnectionMethod) -> String {
        switch option {
        case .automatic:
            L10n.string(
                "mobile.onboarding.connect.method.automatic",
                defaultValue: "Iroh"
            )
        case .tailscale:
            L10n.string(
                "mobile.onboarding.connect.method.tailscale",
                defaultValue: "Tailscale Only"
            )
        case .direct:
            L10n.string(
                "mobile.onboarding.connect.method.direct",
                defaultValue: "Direct"
            )
        }
    }

    private static func subtitle(for option: MobileConnectionMethod) -> String {
        switch option {
        case .automatic:
            L10n.string(
                "mobile.onboarding.connect.method.automaticDetail",
                defaultValue: "Requires cmux 0.64.20 or later on your Mac."
            )
        case .tailscale:
            L10n.string(
                "mobile.onboarding.connect.method.tailscaleDetail",
                defaultValue: "Works with cmux 0.64.17 or later. Scan once to authorize the Mac."
            )
        case .direct:
            L10n.string(
                "mobile.onboarding.connect.method.directDetail",
                defaultValue: "Dials only the direct addresses you add for each computer."
            )
        }
    }

    private static func systemImage(for option: MobileConnectionMethod) -> String {
        switch option {
        case .automatic: "bolt.fill"
        case .tailscale: "qrcode"
        case .direct: "network"
        }
    }

    private static func accessibilityIdentifier(for option: MobileConnectionMethod) -> String {
        switch option {
        case .automatic: "MobileOnboardingConnectionMethodAutomatic"
        case .tailscale: "MobileOnboardingConnectionMethodTailscale"
        case .direct: "MobileOnboardingConnectionMethodDirect"
        }
    }

    private func optionCard(_ option: MobileConnectionMethod) -> some View {
        let isSelected = method == option
        return Button {
            onSelect(option)
        } label: {
            HStack(spacing: density.pickerRowSpacing) {
                Image(systemName: Self.systemImage(for: option))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: density.pickerIconWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(for: option))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(Self.subtitle(for: option))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, density.pickerHorizontalPadding)
            .padding(.vertical, density.pickerVerticalPadding)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: density.pickerCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: density.pickerCornerRadius, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(Self.accessibilityIdentifier(for: option))
    }
}

private extension OnboardingConnectionVisualDensity {
    var pickerOptionSpacing: CGFloat {
        switch self {
        case .regular: 10
        case .compact: 4
        }
    }

    var pickerRowSpacing: CGFloat {
        switch self {
        case .regular: 12
        case .compact: 6
        }
    }

    var pickerIconWidth: CGFloat {
        switch self {
        case .regular: 26
        case .compact: 20
        }
    }

    var pickerHorizontalPadding: CGFloat {
        switch self {
        case .regular: 16
        case .compact: 10
        }
    }

    var pickerVerticalPadding: CGFloat {
        switch self {
        case .regular: 12
        case .compact: 6
        }
    }

    var pickerCornerRadius: CGFloat {
        switch self {
        case .regular: 16
        case .compact: 14
        }
    }
}
#endif
