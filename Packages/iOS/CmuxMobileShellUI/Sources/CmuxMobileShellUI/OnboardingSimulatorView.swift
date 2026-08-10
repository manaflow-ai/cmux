#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingSimulatorView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingSimulatorScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.simulator.body",
                    defaultValue: "Stream it live and tap, type, and swipe from your phone."
                ),
                visual: OnboardingScreenshot(
                    content: .simulator,
                    accessibilityLabel: title
                )
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.simulator.title",
            defaultValue: "Control your Mac's iOS Simulator"
        )
    }
}
#endif
