import Foundation

/// Text of the Add Server card (Resources/Localizable.xcstrings).
extension ServerStrings {
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var enterServerCode: String { s("approver.subtitle", "Enter the code the server shows.") }
    static var codeHint: String { s("approver.codeHint", "8 letters and digits, as the server prints them.") }
    static var lookingUp: String { s("approver.lookingUp", "Looking up the server…") }
    static var codeExpiryHint: String { s("approver.expiryHint", "Codes expire after 10 minutes. Ask the server for a new code.") }
    static var wordsQuestion: String { s("approver.wordsQuestion", "Do these words match the server?") }
    static var wordsWarning: String {
        s("approver.wordsWarning", "If any word differs, deny. Someone else's server could be using this code.")
    }
    static var deny: String { s("approver.deny", "Deny") }
    static var adding: String { s("approver.adding", "Adding…") }
    static var tryAgain: String { s("approver.retry", "Try Again") }
    static var done: String { s("approver.done", "Done") }
    static func added(_ name: String) -> String { String(format: s("approver.added", "%@ added"), name) }
    static var addedDetail: String { s("approver.addedDetail", "It is paired with your team.") }

    /// The Escape button's title: Deny once a server is on the card, else Cancel.
    static func escapeTitle(_ step: AddServerStep) -> String {
        switch step {
        case .review, .approving, .approveFailed: deny
        case .enterCode, .lookingUp, .codeRefused, .added: cancel
        }
    }

    /// The Return button's title.
    static func returnTitle(_ step: AddServerStep) -> String {
        switch step {
        case .approving: adding
        case .approveFailed: tryAgain
        case .added: done
        case .enterCode, .lookingUp, .codeRefused, .review: approve
        }
    }
}
