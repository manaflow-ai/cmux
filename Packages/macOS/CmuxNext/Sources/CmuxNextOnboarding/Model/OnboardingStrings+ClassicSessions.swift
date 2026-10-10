import Foundation

extension OnboardingStrings {
    static var classicSessionsTitle: String { String(localized: "onboarding.classicSessions.title", defaultValue: "Bring over your cmux workspaces", bundle: .module) }
    static var classicSessionsScanning: String { String(localized: "onboarding.classicSessions.scanning", defaultValue: "Looking for a classic cmux session…", bundle: .module) }
    static var classicSessionsEmpty: String { String(localized: "onboarding.classicSessions.empty", defaultValue: "No classic cmux session was found on this Mac.", bundle: .module) }
    static var classicSessionsError: String { String(localized: "onboarding.classicSessions.error", defaultValue: "The classic cmux session could not be read.", bundle: .module) }
}
