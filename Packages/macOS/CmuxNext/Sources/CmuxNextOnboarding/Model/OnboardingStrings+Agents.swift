import Foundation

/// The first-run Agents step's text.
extension OnboardingStrings {
    /// The window's title in the Window menu and for VoiceOver.
    static var agentsTitle: String { String(localized: "onboarding.agents.title", defaultValue: "Agents", bundle: .localizedModule) }
    static var agentsBody: String {
        String(localized: "onboarding.agents.body",
               defaultValue: "Sign in to the agent CLIs you use. You can also do this later in Settings.", bundle: .localizedModule)
    }
}
