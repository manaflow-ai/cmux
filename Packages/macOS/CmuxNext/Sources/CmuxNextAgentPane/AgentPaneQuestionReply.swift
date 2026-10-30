public import Foundation

/// Validity of a renderer's captured answer against one immutable native request. This value
/// grants no person authority: private renderer redemption and a current-generation check must
/// still succeed before reserving and spending the exact intent's one-use ticket.
///
/// Never looser than acpmux's own check (hub/questions.rs check_answers, check_annotations); a
/// choice-only multi-select answer is split on ", " exactly as acpmux splits it. Its size and count
/// limits are the pane relay's (AcpmuxPaneMethods breaksAnswersRule's maximumAnswer* bounds), which
/// already refuse a larger answer today. Beyond those it holds the reply to what the pane's question
/// card sends (webviews question/model.ts answerProblems and reply): one choice on a single-select
/// item and no Other on a choice-only one, for Codex too. It covers question cards only (a request
/// with a normalized question); a plain permission card's option-only reply goes through
/// AgentPaneAskAnswer instead.
public nonisolated struct AgentPaneQuestionReply: Sendable, Equatable {
    public enum Failure: String, Error, Sendable, Equatable {
        case malformed, question, option, answers, annotations
    }

    /// Immutable validation data only. Construct from a captured native request, never page
    /// metadata. This type carries no connection, generation, nonce, person proof, or ticket.
    public struct Input: Sendable, Equatable {
        public let sessionId: String
        public let permissionId: String
        public let requestJSON: String
        public let requestDigest: String

        public init(sessionId: String, permissionId: String, requestJSON: String, requestDigest: String) {
            self.sessionId = sessionId
            self.permissionId = permissionId
            self.requestJSON = requestJSON
            self.requestDigest = requestDigest
        }
    }

    public let input: Input
    public let intent: AgentPaneGestureIntent
    public let canonicalJSON: String

    /// Only a parse bound, above the largest reply the pane relay passes (its maximumAnswer* and
    /// maximumAnnotationBytes bounds, per item); the per-field limits below are what decide.
    static let maximumReplyBytes = 64 << 20
    /// The captured native request, bounded the same way; acpmux sent it.
    static let maximumRequestBytes = 64 << 20
    static let maximumNotesBytes = 8192

    public init(input: Input, replyJSON: String) throws(Failure) {
        guard replyJSON.utf8.count <= Self.maximumReplyBytes, AcpmuxJSONKeys.verdict(replyJSON) == .clean,
              let reply = (try? JSONSerialization.jsonObject(with: Data(replyJSON.utf8))) as? [String: Any],
              Set(reply.keys).isSubset(of: ["optionId", "answers", "annotations"]),
              let option = reply["optionId"] as? String else { throw .malformed }
        guard input.requestJSON.utf8.count <= Self.maximumRequestBytes,
              AcpmuxJSONKeys.verdict(input.requestJSON) == .clean,
              let request = (try? JSONSerialization.jsonObject(with: Data(input.requestJSON.utf8))) as? [String: Any],
              AcpmuxSecretKey.canonicalDigest(request) == input.requestDigest,
              let normalized = AcpmuxPermissionPrompt.question(request),
              let harness = normalized["harness"] as? String, ["claude", "chief", "codex"].contains(harness),
              let items = normalized["items"] as? [[String: Any]],
              (1...AcpmuxPaneMethods.maximumAnswerItems).contains(items.count) else { throw .question }
        guard let options = request["options"] as? [[String: Any]], !options.isEmpty else { throw .question }
        // The one allow-once option, as AcpmuxPermissionPrompt.onceOption reads it: a request
        // offering two is ambiguous, so no reply to it is valid.
        guard let once = AcpmuxPermissionPrompt.onceOption(allow: true, offered: options),
              Self.equalBytes(once, option) else { throw .option }
        guard let answers = reply["answers"] as? [String: Any],
              Self.validAnswers(answers, items: items, codex: harness == "codex") else { throw .answers }
        if let annotations = reply["annotations"],
           !Self.validAnnotations(annotations, request: request, items: items, harness: harness) { throw .annotations }
        var params = reply
        // Identity comes only from the captured input, never the renderer payload.
        params["sessionId"] = input.sessionId
        params["permissionId"] = input.permissionId
        guard let intent = AgentPaneGestureIntent(gestureParams: ["intent": ["method": "_acpmux/permission_respond", "params": params]]),
              let canonical = AcpmuxSecretKey.canonicalJSON(reply) else { throw .malformed }
        self.input = input
        self.intent = intent
        self.canonicalJSON = canonical
    }

    private static func validAnswers(_ answers: [String: Any], items: [[String: Any]], codex: Bool) -> Bool {
        guard answers.count == items.count else { return false }
        var seen = Set<Data>()
        for item in items {
            guard let allowsOther = boolean(item["allowsOther"], default: true),
                  let multiSelect = boolean(item["multiSelect"], default: false) else { return false }
            guard let key = item[codex ? "id" : "prompt"] as? String, !key.isEmpty,
                  key.utf8.count <= AcpmuxPaneMethods.maximumAnswerBytes, seen.insert(Data(key.utf8)).inserted,
                  let value = answers.first(where: { equalBytes($0.key, key) })?.value else { return false }
            let labels: [String]
            if codex {
                guard let value = value as? [String: Any], Set(value.keys) == ["answers"],
                      let list = value["answers"] as? [String],
                      (1...AcpmuxPaneMethods.maximumAnswerListStrings).contains(list.count),
                      multiSelect || list.count == 1 else { return false }
                labels = list
            } else {
                guard let text = value as? String else { return false }
                labels = [text]
            }
            guard labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= AcpmuxPaneMethods.maximumAnswerBytes }) else { return false }
            if !allowsOther {
                let options = item["options"] as? [[String: Any]] ?? []
                let allowed = options.compactMap { $0["label"] as? String }
                let picked = !codex && multiSelect
                    ? labels[0].components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    : labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                // Match the owner's choice-only validation (acpmux hub/questions.rs check_answers),
                // including distinct multi choices: it splits a multi answer on ", " too, so a
                // label holding ", " is refused there as well and accepting it here would not help.
                // A Codex answer is a list of the chosen options' labels, which may repeat when two
                // options share a label; acpmux checks no Codex labels at all.
                guard codex || Set(picked.map { Data($0.utf8) }).count == picked.count,
                      picked.allSatisfy({ picked in allowed.contains(where: { equalBytes($0, picked) }) }) else { return false }
            }
        }
        return true
    }

    /// acpmux hub/questions.rs check_annotations: only the real Claude AskUserQuestion reads
    /// these. Previews match its original native tool input after trimming; notes are bounded.
    /// As there, a preview is any of the question's option previews, not only the answered one's:
    /// an Other answer can still name the mockup it was written against. Any other question's
    /// annotations pass unchecked, as acpmux drops them unread.
    private static func validAnnotations(_ raw: Any, request: [String: Any], items: [[String: Any]], harness: String) -> Bool {
        let tool = request["toolCall"] as? [String: Any]
        let meta = tool?["_meta"] as? [String: Any]
        let asks = harness == "claude" && (meta?["claude"] as? [String: Any])?["tool"] as? String == "AskUserQuestion"
        guard asks, let originals = (tool?["rawInput"] as? [String: Any])?["questions"] as? [[String: Any]] else { return true }
        guard let annotations = raw as? [String: Any],
              (1...AcpmuxPaneMethods.maximumAnswerItems).contains(annotations.count) else { return false }
        for (key, value) in annotations {
            guard items.contains(where: { ($0["prompt"] as? String).map { equalBytes($0, key) } == true }),
                  let original = originals.first(where: { ($0["question"] as? String).map { equalBytes($0, key) } == true }),
                  let note = value as? [String: Any], !note.isEmpty,
                  Set(note.keys).isSubset(of: ["preview", "notes"]) else { return false }
            if let rawPreview = note["preview"] {
                guard let preview = rawPreview as? String, preview.utf8.count <= AcpmuxPaneMethods.maximumAnnotationBytes,
                      let options = original["options"] as? [[String: Any]],
                      options.contains(where: { option in
                          guard let text = option["preview"] as? String else { return false }
                          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                          return !trimmed.isEmpty && equalBytes(trimmed, preview.trimmingCharacters(in: .whitespacesAndNewlines))
                      }) else { return false }
            }
            if let rawNotes = note["notes"] {
                guard let text = rawNotes as? String, text.utf8.count <= maximumNotesBytes,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            }
        }
        return true
    }

    /// Shared and web decoders accept absent/null defaults but reject numeric Bool coercion.
    private static func boolean(_ raw: Any?, default fallback: Bool) -> Bool? {
        guard let raw, !(raw is NSNull) else { return fallback }
        guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
        return flag.boolValue
    }

    private static func equalBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}
