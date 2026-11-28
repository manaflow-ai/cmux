import Foundation

/// The question card's words (HomeQuestionRowProvider).
extension CmuxStrings {
    static var questionSend: String { String(localized: "home.question.send", defaultValue: "Send", table: "CmuxHome", bundle: .module) }
    static var questionAnswered: String { String(localized: "home.question.answered", defaultValue: "Answered", table: "CmuxHome", bundle: .module) }
    static var questionExpired: String { String(localized: "home.question.stale", defaultValue: "This question is no longer open", table: "CmuxHome", bundle: .module) }
}
