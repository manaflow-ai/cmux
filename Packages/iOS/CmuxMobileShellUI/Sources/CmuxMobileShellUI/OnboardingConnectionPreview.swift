#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionPreview: View {
    let isReady: Bool

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                deviceCircle(systemImage: "desktopcomputer", tint: .indigo)

                Image(systemName: isReady ? "checkmark" : "qrcode")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isReady ? .green : .secondary)
                    .frame(width: 46, height: 46)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)

                deviceCircle(systemImage: "iphone", tint: .blue)
            }

            Label(
                L10n.string(
                    "mobile.onboarding.connect.trust",
                    defaultValue: "Encrypted end to end"
                ),
                systemImage: "lock.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileOnboardingConnectionPreview")
    }

    private func deviceCircle(systemImage: String, tint: Color) -> some View {
        Circle()
            .fill(tint.gradient)
            .frame(width: 78, height: 78)
            .overlay {
                Image(systemName: systemImage)
                    .font(.title.weight(.medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
#endif
