import Foundation

/// Make cmux Yours' text the window itself shows (its page owns the rest).
extension OnboardingStrings {
    /// The window title of the first run's setup screen (cmux#48416).
    static var makeItYoursTitle: String { String(localized: "onboarding.makeItYours.title", defaultValue: "Make cmux Yours", bundle: .localizedModule) }
}
