import Foundation

/// The cmux Tools step's text the window itself shows (its page owns the rest).
extension OnboardingStrings {
    /// The window's title in the Window menu and for VoiceOver.
    static var agentToolsTitle: String { String(localized: "onboarding.agentTools.title", defaultValue: "cmux Tools", bundle: .localizedModule) }
    /// The window title of the first run's setup screen (cmux#48416).
    static var makeItYoursTitle: String { String(localized: "onboarding.makeItYours.title", defaultValue: "Make cmux Yours", bundle: .localizedModule) }
    /// The primary button before the person answered.
    static var turnOnTools: String {
        String(localized: "onboarding.agentTools.add", defaultValue: "Turn On", bundle: .localizedModule)
    }
}
