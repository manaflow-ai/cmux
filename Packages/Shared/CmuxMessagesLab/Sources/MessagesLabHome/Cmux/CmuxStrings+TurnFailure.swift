import Foundation

/// The failed-turn card's words (HomeTurnFailureRowProvider).
extension CmuxStrings {
    static var turnFailureLimit: String {
        String(localized: "home.turnFailure.limit", defaultValue: "The Chief reached its usage limit.", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureSignedOut: String {
        String(localized: "home.turnFailure.signedOut", defaultValue: "The Chief's agent is signed out.", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureNetwork: String {
        String(localized: "home.turnFailure.network", defaultValue: "The Chief couldn't reach its model.", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureService: String {
        String(localized: "home.turnFailure.service", defaultValue: "The model service had a problem.", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureGeneric: String {
        String(localized: "home.turnFailure.generic", defaultValue: "The Chief's reply failed.", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureRetry: String {
        String(localized: "home.turnFailure.retry", defaultValue: "Retry", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureCopy: String {
        String(localized: "home.turnFailure.copy", defaultValue: "Copy error", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureCopied: String {
        String(localized: "home.turnFailure.copied", defaultValue: "Copied", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureDetails: String {
        String(localized: "home.turnFailure.details", defaultValue: "Details", table: "CmuxHome", bundle: .module)
    }
    static var turnFailureHideDetails: String {
        String(localized: "home.turnFailure.hideDetails", defaultValue: "Hide details", table: "CmuxHome", bundle: .module)
    }
}
