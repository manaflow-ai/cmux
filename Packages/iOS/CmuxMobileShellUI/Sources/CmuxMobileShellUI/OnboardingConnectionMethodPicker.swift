#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Auto-Connect vs Tailscale choice on the onboarding connect page.
/// Selection persists through the shared connection-method store, so the
/// Settings picker shows the same value afterward.
struct OnboardingConnectionMethodPicker: View {
    let method: MobileConnectionMethod
    let onSelect: (MobileConnectionMethod) -> Void

    var body: some View {
        VStack(spacing: 10) {
            optionCard(
                .automatic,
                title: L10n.string(
                    "mobile.onboarding.connect.method.automatic",
                    defaultValue: "Auto-Connect"
                ),
                subtitle: L10n.string(
                    "mobile.onboarding.connect.method.automaticDetail",
                    defaultValue: "Recommended. Finds your Mac with no setup."
                ),
                systemImage: "bolt.fill",
                accessibilityIdentifier: "MobileOnboardingConnectionMethodAutomatic"
            )
            optionCard(
                .tailscale,
                title: L10n.string(
                    "mobile.onboarding.connect.method.tailscale",
                    defaultValue: "Tailscale"
                ),
                subtitle: L10n.string(
                    "mobile.onboarding.connect.method.tailscaleDetail",
                    defaultValue: "Uses your Tailscale network. Scan the pairing code on your Mac."
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
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 26)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
#endif
