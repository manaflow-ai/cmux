#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The connected scene's Keep Mac Awake ask: one row with the live per-Mac
/// toggle, so answering it is the real mutation, not a deferred preference.
/// The store's optimistic value drives the switch; a failed mutation rolls the
/// store back and the switch follows, so the card carries no error state of
/// its own (the computer detail keeps the full retry/error surface).
struct OnboardingKeepAwakeCard: View {
    let offer: OnboardingKeepAwakeOffer
    let density: OnboardingConnectionVisualDensity
    let onSet: (Bool) async -> Void

    var body: some View {
        HStack(spacing: density.keepAwakeRowSpacing) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: density.keepAwakeIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(L10n.string(
                    "mobile.onboarding.keepAwake.caption",
                    defaultValue: "Prevent your Mac from sleeping while cmux is open."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Toggle(
                title,
                isOn: Binding(
                    get: { offer.isEnabled },
                    set: { enabled in
                        Task { @MainActor in
                            await onSet(enabled)
                        }
                    }
                )
            )
            .labelsHidden()
            .disabled(offer.isBusy)
            .accessibilityIdentifier("MobileOnboardingKeepAwakeToggle")
        }
        .padding(.horizontal, density.keepAwakeHorizontalPadding)
        .padding(.vertical, density.keepAwakeVerticalPadding)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: density.keepAwakeCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: density.keepAwakeCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingKeepAwakeCard")
    }

    private var title: String {
        L10n.string(
            "mobile.settings.keepMacAwake",
            defaultValue: "Keep Mac Awake"
        )
    }
}

private extension OnboardingConnectionVisualDensity {
    var keepAwakeRowSpacing: CGFloat {
        switch self {
        case .regular: 12
        case .compact: 6
        }
    }

    var keepAwakeIconWidth: CGFloat {
        switch self {
        case .regular: 26
        case .compact: 20
        }
    }

    var keepAwakeHorizontalPadding: CGFloat {
        switch self {
        case .regular: 16
        case .compact: 10
        }
    }

    var keepAwakeVerticalPadding: CGFloat {
        switch self {
        case .regular: 12
        case .compact: 6
        }
    }

    var keepAwakeCornerRadius: CGFloat {
        switch self {
        case .regular: 16
        case .compact: 14
        }
    }
}
#endif
