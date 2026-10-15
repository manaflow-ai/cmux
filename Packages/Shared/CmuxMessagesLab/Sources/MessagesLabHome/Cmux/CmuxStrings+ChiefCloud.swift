import Foundation

/// The Chief's question card, Cloud provisioning row and result card
/// (Resources/CmuxHome.xcstrings).
extension CmuxStrings {
    /// VoiceOver's name for the question card.
    static var questionRole: String {
        String(localized: "home.question.role", defaultValue: "Question", table: "CmuxHome", bundle: .module)
    }
    /// The card's primary button when the Chief named none.
    static var questionSubmit: String {
        String(localized: "home.question.submit", defaultValue: "Submit", table: "CmuxHome", bundle: .module)
    }
    /// The answered card's receipt: "Chose 8 GB".
    static func questionChose(_ choice: String) -> String {
        String(localized: "home.question.chose", defaultValue: "Chose \(choice)", table: "CmuxHome", bundle: .module)
    }
    static var questionCancelled: String {
        String(localized: "home.question.cancelled", defaultValue: "Cancelled", table: "CmuxHome", bundle: .module)
    }

    /// The provisioning row while the machine is created; `elapsed` is a short duration ("40s").
    static func cloudCreating(_ elapsed: String) -> String {
        String(localized: "home.cloud.creating", defaultValue: "Creating cloud machine… \(elapsed)", table: "CmuxHome", bundle: .module)
    }
    static var cloudReady: String {
        String(localized: "home.cloud.ready", defaultValue: "Cloud machine ready", table: "CmuxHome", bundle: .module)
    }
    static var cloudFailed: String {
        String(localized: "home.cloud.failed", defaultValue: "Couldn't create cloud machine", table: "CmuxHome", bundle: .module)
    }
    /// The result card's action.
    static var cloudOpenWorkspace: String {
        String(localized: "home.cloud.openWorkspace", defaultValue: "Open Workspace", table: "CmuxHome", bundle: .module)
    }
    /// VoiceOver's name for the result card.
    static var cloudResultRole: String {
        String(localized: "home.cloud.resultRole", defaultValue: "Cloud workspace", table: "CmuxHome", bundle: .module)
    }
    static var cloudStatusWorking: String {
        String(localized: "home.cloud.status.working", defaultValue: "Agent working", table: "CmuxHome", bundle: .module)
    }
    static var cloudStatusReady: String {
        String(localized: "home.cloud.status.ready", defaultValue: "Ready", table: "CmuxHome", bundle: .module)
    }
    static var cloudStatusFailed: String {
        String(localized: "home.cloud.status.failed", defaultValue: "Failed", table: "CmuxHome", bundle: .module)
    }
}
