import Foundation

extension OnboardingStrings {
    static var classicSessionsTitle: String { String(localized: "onboarding.classicSessions.title", defaultValue: "Bring over your cmux workspaces", bundle: .module) }
    static var classicSessionsSubtitle: String { String(localized: "onboarding.classicSessions.subtitle", defaultValue: "Import names, folders, tabs and split layouts from classic cmux. Saved commands are never run.", bundle: .module) }
    static var classicSessionsScanning: String { String(localized: "onboarding.classicSessions.scanning", defaultValue: "Looking for a classic cmux session…", bundle: .module) }
    static var classicSessionsEmpty: String { String(localized: "onboarding.classicSessions.empty", defaultValue: "No classic cmux session was found on this Mac.", bundle: .module) }
}
