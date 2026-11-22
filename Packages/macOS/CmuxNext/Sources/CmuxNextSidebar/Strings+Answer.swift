import Foundation

extension Strings {
    /// An answerable row's allow button (the Needs You tray, a Priority row): allows the tool call once.
    static var answerAllow: String { String(localized: "sidebar.answer.allow", defaultValue: "Allow", bundle: .localizedModule) }
    /// An answerable row's deny button.
    static var answerDeny: String { String(localized: "sidebar.answer.deny", defaultValue: "Deny", bundle: .localizedModule) }
    /// The allow button, for VoiceOver.
    static var answerAllowLabel: String {
        String(localized: "sidebar.a11y.answer.allow", defaultValue: "Allow once", bundle: .localizedModule)
    }
    /// The deny button, for VoiceOver.
    static var answerDenyLabel: String {
        String(localized: "sidebar.a11y.answer.deny", defaultValue: "Deny this request", bundle: .localizedModule)
    }
    /// The key that presses an answer button while its row has the focus, for VoiceOver ("Press Y").
    static func answerKeyHelp(_ key: String) -> String {
        String(localized: "sidebar.a11y.answer.key", defaultValue: "Press \(key)", bundle: .localizedModule)
    }
}
