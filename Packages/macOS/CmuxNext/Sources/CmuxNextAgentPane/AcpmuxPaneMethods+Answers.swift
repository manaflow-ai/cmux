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
    /// ``maximumAnswerBytes`` UTF-8 bytes (per string, never a list's strings together).
    static func breaksAnswersRule(_ object: [String: Any]?, options: AcpmuxPermissionOptions) -> Bool {
        answersRuleViolation(object, options: options) != nil
    }

    /// Which part of the answers rule a frame breaks, in a few words that name fields and bounds,
    /// never a value (the app log's cause, ``AgentPaneRefusalLog``); nil when it keeps the rule.
    static func answersRuleViolation(_ object: [String: Any]?, options: AcpmuxPermissionOptions) -> String? {
        guard let object, object["method"] as? String == "_acpmux/permission_respond",
              let params = object["params"] as? [String: Any] else { return nil }
        if let annotations = params["annotations"],
           let violation = annotationsRuleViolation(annotations, params: params, options: options) {
            return violation
        }
        guard let rawAnswers = params["answers"] else { return nil }
        guard let permission = params["permissionId"] as? String else { return "answers without a permissionId" }
        guard let keys = options.questionKeys(permissionId: permission) else { return "answers for no pending question" }
        guard let answers = rawAnswers as? [String: Any], (1...maximumAnswerItems).contains(answers.count) else {
            return "answers not an object of 1 to \(maximumAnswerItems) items"
        }
        for (key, value) in answers {
            if key.utf8.count > maximumAnswerBytes { return "answers item key over \(maximumAnswerBytes) bytes" }
            if !keys.contains(key) { return "answers item not one of the question's" }
            if !fitsAnswer(value) { return "answers item value not a bounded string, list or {answers}" }
        }
        return nil
    }

    /// The most UTF-8 bytes of one annotation string (a chosen preview or the notes).
    static let maximumAnnotationBytes = 65536

    /// Whether a page frame's `annotations` (Claude Code's AskUserQuestion answer field: question
    /// text -> `{preview?, notes?}`) break the rule. They go only beside `answers`, to a pending
    /// question the daemon sent this pane, keyed by its own items like the answers; each value is
    /// an object of `preview` and `notes` strings of at most ``maximumAnnotationBytes`` bytes.
    /// acpmux checks the preview against the question's own options and bounds the notes.
    static func breaksAnnotationsRule(_ raw: Any, params: [String: Any], options: AcpmuxPermissionOptions) -> Bool {
        annotationsRuleViolation(raw, params: params, options: options) != nil
    }

    /// Which part of the annotations rule `raw` breaks (see ``answersRuleViolation(_:options:)``).
    static func annotationsRuleViolation(_ raw: Any, params: [String: Any], options: AcpmuxPermissionOptions) -> String? {
        guard params["answers"] != nil else { return "annotations without answers" }
        guard let permission = params["permissionId"] as? String else { return "annotations without a permissionId" }
        guard let keys = options.questionKeys(permissionId: permission) else { return "annotations for no pending question" }
        guard let annotations = raw as? [String: Any], (1...maximumAnswerItems).contains(annotations.count) else {
            return "annotations not an object of 1 to \(maximumAnswerItems) items"
        }
        for (key, value) in annotations {
            if !keys.contains(key) { return "annotations item not one of the question's" }
            guard let note = value as? [String: Any], !note.isEmpty else { return "annotations item not a non-empty object" }
            for (field, text) in note {
                if !["preview", "notes"].contains(field) { return "annotations item field other than preview or notes" }
                guard let text = text as? String, text.utf8.count <= maximumAnnotationBytes else {
                    return "annotations item \(field) not a string of at most \(maximumAnnotationBytes) bytes"
                }
            }
        }
        return nil
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
        return list.allSatisfy(fitsAnswerString)
    }

    private static func fitsAnswerString(_ value: Any) -> Bool {
        guard let text = value as? String else { return false }
        return text.utf8.count <= maximumAnswerBytes
    }
}
