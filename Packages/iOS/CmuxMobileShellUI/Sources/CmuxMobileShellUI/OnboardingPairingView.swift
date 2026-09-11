#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Explains the Mac-side opt-in before onboarding starts discovery.
struct OnboardingPairingView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingPairingScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.pairing.body",
                    defaultValue: "cmux keeps iOS pairing off until you choose it. Enable it in cmux Settings > Mobile on your Mac, then use the same cmux account on both devices."
                ),
                visual: pairingVisual,
                bodyLineReservation: 4
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.pairing.title",
            defaultValue: "Choose which Macs can connect"
        )
    }

    private var pairingVisual: some View {
        VStack(spacing: 22) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 72, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 16) {
                pairingStep(
                    systemImage: "macbook",
                    title: L10n.string(
                        "mobile.onboarding.pairing.macLabel",
                        defaultValue: "On your Mac"
                    ),
                    detail: L10n.string(
                        "mobile.onboarding.pairing.macDetail",
                        defaultValue: "Settings > Mobile > Enable iOS pairing"
                    )
                )

                pairingStep(
                    systemImage: "iphone",
                    title: L10n.string(
                        "mobile.onboarding.pairing.phoneLabel",
                        defaultValue: "On this iPhone"
                    ),
                    detail: L10n.string(
                        "mobile.onboarding.pairing.phoneDetail",
                        defaultValue: "Sign in to the same cmux account"
                    )
                )
            }
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func pairingStep(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
#endif
