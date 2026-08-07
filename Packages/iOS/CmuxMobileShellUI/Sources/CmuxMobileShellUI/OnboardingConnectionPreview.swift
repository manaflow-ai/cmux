#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionPreview: View {
    let phase: OnboardingConnectionPhase
    let density: OnboardingConnectionVisualDensity

    var body: some View {
        VStack(spacing: density.previewContentSpacing) {
            HStack(spacing: density.previewDeviceSpacing) {
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
        .padding(.horizontal, density.previewHorizontalPadding)
        .padding(.vertical, density.previewVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: density.previewCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: density.previewCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingConnectionPreview")
    }

    private func deviceIcon(systemImage: String, tint: Color) -> some View {
        Circle()
            .fill(tint.gradient)
            .frame(width: density.previewDeviceSize, height: density.previewDeviceSize)
            .overlay {
                Image(systemName: systemImage)
                    .font(density.previewDeviceFont.weight(.medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var accountLink: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: density.previewAccountSize, height: density.previewAccountSize)

                Image(systemName: phase == .ready
                    ? "person.crop.circle.badge.checkmark"
                    : "person.crop.circle")
                    .font(density.previewAccountFont.weight(.semibold))
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
        case .idle:
            Label(
                L10n.string(
                    "mobile.onboarding.connect.idleStatus",
                    defaultValue: "Ready to look for your Mac"
                ),
                systemImage: "magnifyingglass"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("MobileOnboardingConnectionIdle")
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
                    defaultValue: "Couldn’t connect to your Mac yet"
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

private extension OnboardingConnectionVisualDensity {
    var previewContentSpacing: CGFloat {
        switch self {
        case .regular: 20
        case .compact: 6
        }
    }

    var previewDeviceSpacing: CGFloat {
        switch self {
        case .regular: 14
        case .compact: 8
        }
    }

    var previewHorizontalPadding: CGFloat {
        switch self {
        case .regular: 24
        case .compact: 10
        }
    }

    var previewVerticalPadding: CGFloat {
        switch self {
        case .regular: 28
        case .compact: 8
        }
    }

    var previewCornerRadius: CGFloat {
        switch self {
        case .regular: 28
        case .compact: 18
        }
    }

    var previewDeviceSize: CGFloat {
        switch self {
        case .regular: 74
        case .compact: 40
        }
    }

    var previewDeviceFont: Font {
        switch self {
        case .regular: .title
        case .compact: .title3
        }
    }

    var previewAccountSize: CGFloat {
        switch self {
        case .regular: 52
        case .compact: 36
        }
    }

    var previewAccountFont: Font {
        switch self {
        case .regular: .title2
        case .compact: .body
        }
    }
}
#endif
