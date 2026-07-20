#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Preserves the second onboarding position without advertising unfinished UI.
/// A shipped feature can replace this empty content without changing the flow.
struct OnboardingReservedView: View {
    let onBack: () -> Void
    let onSkip: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingSceneContainer(
            stage: .reserved,
            title: "",
            message: "",
            primaryTitle: L10n.string(
                "mobile.onboarding.continue",
                defaultValue: "Continue"
            ),
            secondaryTitle: nil,
            showsBack: true,
            showsSkip: true,
            onBack: onBack,
            onSkip: onSkip,
            onPrimary: onContinue,
            onSecondary: {},
            showsContent: false,
            visual: EmptyView()
        )
    }
}
#endif
