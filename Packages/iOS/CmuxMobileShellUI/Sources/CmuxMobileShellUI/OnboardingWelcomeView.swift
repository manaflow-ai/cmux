#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The single value pitch before any ask: agents keep running on the Mac and
/// this phone is the window into them. Uses the shipped workspace-list capture
/// inside the product frame.
struct OnboardingWelcomeView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingWelcomeScene")

            OnboardingSceneContent(
                title: title,
                message: L10n.string(
                    "mobile.onboarding.welcome.body",
                    defaultValue: "Watch every workspace live, and step in the moment an agent needs you."
                ),
                visual: OnboardingScreenshot(
                    content: .workspaces,
                    accessibilityLabel: title
                )
            )
        }
    }

    private var title: String {
        L10n.string(
            "mobile.onboarding.welcome.title",
            defaultValue: "Your agents keep working on your Mac"
        )
    }
}
#endif
