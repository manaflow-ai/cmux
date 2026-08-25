#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Auto-Connect vs Tailscale choice on the onboarding connect page.
/// Selection persists through the shared connection-method store, so the
/// Settings picker shows the same value afterward.
struct OnboardingConnectionMethodPicker: View {
    let method: MobileConnectionMethod
    let density: OnboardingConnectionVisualDensity
    let onSelect: (MobileConnectionMethod) -> Void

    var body: some View {
        VStack(spacing: density.pickerOptionSpacing) {
            optionCard(
                .automatic,
                title: L10n.string(
                    "mobile.onboarding.connect.method.automatic",
                    defaultValue: "Iroh"
                ),
                subtitle: L10n.string(
                    "mobile.onboarding.connect.method.automaticDetail",
                    defaultValue: "Requires cmux 0.64.20 or later on your Mac."
                ),
                systemImage: "bolt.fill",
                accessibilityIdentifier: "MobileOnboardingConnectionMethodAutomatic"
            )
            optionCard(
                .tailscale,
                title: L10n.string(
                    "mobile.onboarding.connect.method.tailscale",
                    defaultValue: "Tailscale Only"
                ),
                subtitle: L10n.string(
                    "mobile.onboarding.connect.method.tailscaleDetail",
                    defaultValue: "Works with cmux 0.64.17 or later. Scan once to authorize the Mac."
                ),
                systemImage: "qrcode",
                accessibilityIdentifier: "MobileOnboardingConnectionMethodTailscale"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingConnectionMethodPicker")
    }

    private func optionCard(
        _ option: MobileConnectionMethod,
        title: String,
        subtitle: String,
        systemImage: String,
        accessibilityIdentifier: String
    ) -> some View {
        let isSelected = method == option
        return Button {
            onSelect(option)
        } label: {
            HStack(spacing: density.pickerRowSpacing) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: density.pickerIconWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
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
        .accessibilityIdentifier(accessibilityIdentifier)
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
