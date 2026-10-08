import Foundation

/// The answers rule of ``AcpmuxPaneMethods``: what `answers` on `_acpmux/permission_respond` may be
/// (plans/cmux-next/agent-questions.md). The daemon checks an answer against its question again;
/// the relay refuses everything a question card cannot have sent, before the daemon sees it.
nonisolated extension AcpmuxPaneMethods {
    /// The most items one answer may hold.
    static let maximumAnswerItems = 64
    /// The most strings one item's list may hold.
    static let maximumAnswerListStrings = 64
    /// The most UTF-8 bytes of one item key, and of each string of an item's value.
    static let maximumAnswerBytes = 4096

    /// Whether a page frame's `answers` breaks the rule. Answers go only to a pending question the
    /// daemon sent this pane (``AcpmuxPermissionOptions/questionKeys(permissionId:)``), never to a
    /// tool permission. They are an object of 1 to ``maximumAnswerItems`` of the question's own
    /// items (an item id or prompt), and each value is a string, a list of at most
    /// ``maximumAnswerListStrings`` strings, or Codex's `{answers: [string]}` with that one key. Each key and each string is at most
    /// ``maximumAnswerBytes`` UTF-8 bytes; strings in a list are bounded together by the same limit.
    static func breaksAnswersRule(_ object: [String: Any]?, options: AcpmuxPermissionOptions) -> Bool {
        guard let object, object["method"] as? String == "_acpmux/permission_respond",
              let params = object["params"] as? [String: Any], let rawAnswers = params["answers"] else { return false }
        guard let permission = params["permissionId"] as? String,
              let keys = options.questionKeys(permissionId: permission),
              let answers = rawAnswers as? [String: Any],
              (1...maximumAnswerItems).contains(answers.count) else { return true }
        return answers.contains { key, value in
            key.utf8.count > maximumAnswerBytes || !keys.contains(key) || !fitsAnswer(value)
        }
    }

    /// One item's value: a string, a list of strings, or `{answers: [string]}`.
    static func fitsAnswer(_ value: Any) -> Bool {
        if let codex = value as? [String: Any] {
            guard codex.count == 1, let list = codex["answers"] else { return false }
            return fitsAnswerList(list)
        }
        return fitsAnswerString(value) || fitsAnswerList(value)
    }

    private static func fitsAnswerList(_ value: Any) -> Bool {
        guard let list = value as? [Any], list.count <= maximumAnswerListStrings else { return false }
        guard list.allSatisfy(fitsAnswerString) else { return false }
        return list.compactMap { ($0 as? String)?.utf8.count }.reduce(0, +) <= maximumAnswerBytes
    }

    private static func fitsAnswerString(_ value: Any) -> Bool {
        guard let text = value as? String else { return false }
        return text.utf8.count <= maximumAnswerBytes
    }
}
