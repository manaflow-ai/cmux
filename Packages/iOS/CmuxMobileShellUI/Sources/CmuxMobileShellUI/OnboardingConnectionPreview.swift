#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionPreview: View {
    let phase: OnboardingConnectionPhase

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                deviceIcon(systemImage: "desktopcomputer", tint: .indigo)
                accountLink
                deviceIcon(systemImage: "iphone", tint: .blue)
            }

            connectionStatus

            Label(
                L10n.string(
                    "mobile.onboarding.connect.trust",
                    defaultValue: "Encrypted end to end"
                ),
                systemImage: "lock.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingConnectionPreview")
    }

    private func deviceIcon(systemImage: String, tint: Color) -> some View {
        Circle()
            .fill(tint.gradient)
            .frame(width: 74, height: 74)
            .overlay {
                Image(systemName: systemImage)
                    .font(.title.weight(.medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var accountLink: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: 52, height: 52)

                Image(systemName: phase == .ready
                    ? "person.crop.circle.badge.checkmark"
                    : "person.crop.circle")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(phase == .ready ? Color.green : Color.accentColor)
            }

            Text(L10n.string(
                "mobile.onboarding.connect.sameAccount",
                defaultValue: "Same account"
            ))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch phase {
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string(
                    "mobile.onboarding.connect.searching",
                    defaultValue: "Looking for your Mac…"
                ))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("MobileOnboardingConnectionSearching")
        case .fallback:
            Label(
                L10n.string(
                    "mobile.onboarding.connect.fallbackStatus",
                    defaultValue: "No Mac appeared on this account"
                ),
                systemImage: "exclamationmark.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("MobileOnboardingConnectionFallback")
        case .ready:
            Label(
                L10n.string(
                    "mobile.onboarding.connect.connectedStatus",
                    defaultValue: "Connected securely"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)
            .accessibilityIdentifier("MobileOnboardingConnectionReady")
        }
    }
}
#endif
