import Foundation

/// Localized questions are both the chip label and the exact message sent.
struct HomeStarterStrings {
    static func failure(_ name: String) -> String {
        String(format: String(localized: "home.starter.failure", defaultValue: "Check the failure in %@", bundle: .module), name)
    }
    static func running(_ name: String) -> String {
        String(format: String(localized: "home.starter.running", defaultValue: "Check on %@", bundle: .module), name)
    }
    static func review(_ name: String) -> String {
        String(format: String(localized: "home.starter.review", defaultValue: "Review %@", bundle: .module), name)
    }
    static func workspace(_ name: String) -> String {
        String(format: String(localized: "home.starter.workspace", defaultValue: "Plan the next step for %@", bundle: .module), name)
    }
    static var setup: String { String(localized: "home.starter.setup", defaultValue: "Help me open a workspace", bundle: .module) }
    static var agent: String { String(localized: "home.starter.agent", defaultValue: "Help me start an agent", bundle: .module) }
    static var task: String { String(localized: "home.starter.task", defaultValue: "Help me choose my next task", bundle: .module) }
}
