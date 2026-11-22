import Foundation

/// The Add Server card's words (Resources/Localizable.xcstrings, `approver.*`).
nonisolated enum AddServerStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .localizedModule)
    }

    static var title: String { t("approver.title", "Add Server") }
    static var subtitle: String { t("approver.subtitle", "Enter the code the server shows.") }
    static var codeHint: String { t("approver.codeHint", "8 letters and digits, as the server prints them.") }
    static var lookingUp: String { t("approver.lookingUp", "Looking up the server…") }
    static var expiryHint: String { t("approver.expiryHint", "Codes expire after 10 minutes. Ask the server for a new code.") }
    static var wordsQuestion: String { t("approver.wordsQuestion", "Do these words match the server?") }
    static var wordsWarning: String { t("approver.wordsWarning", "If any word differs, deny. Someone else's server could be using this code.") }
    static var name: String { t("approver.name", "Name") }
    static var team: String { t("approver.team", "Team") }
    static var runChief: String { t("approver.runChief", "Run my Chief on this server") }
    static var approve: String { t("approver.approve", "Approve") }
    static var adding: String { t("approver.adding", "Adding…") }
    static var retry: String { t("approver.retry", "Try Again") }
    static var deny: String { t("approver.deny", "Deny") }
    static var cancel: String { t("approver.cancel", "Cancel") }
    static var done: String { t("approver.done", "Done") }
    static func added(_ name: String) -> String { String(format: t("approver.added", "%@ added"), name) }
    static var addedDetail: String { t("approver.addedDetail", "It is paired with your team.") }

    /// A server is on the card: its facts, words and options show, and Cancel reads Deny.
    static func showsServer(_ step: AddServerStep) -> Bool {
        switch step {
        case .review, .approving, .approveFailed: true
        default: false
        }
    }
}
