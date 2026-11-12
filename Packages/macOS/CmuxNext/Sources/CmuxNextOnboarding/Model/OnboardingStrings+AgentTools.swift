import Foundation

/// The cmux Tools step's text the window itself shows (its page owns the rest).
extension OnboardingStrings {
    /// The window's title in the Window menu and for VoiceOver.
    static var agentToolsTitle: String { String(localized: "onboarding.agentTools.title", defaultValue: "cmux Tools", bundle: .module) }
    /// The primary button before the person answered.
    static var addToMyAgents: String {
        String(localized: "onboarding.agentTools.add", defaultValue: "Add to My Agents", bundle: .module)
    }
}
