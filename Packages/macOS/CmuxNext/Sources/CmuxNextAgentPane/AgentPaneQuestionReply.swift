public import Foundation

/// Validity of a renderer's captured answer against one immutable native request. This value
/// grants no person authority: private renderer redemption and a current-generation check must
/// still succeed before reserving and spending the exact intent's one-use ticket.
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

    static let maximumReplyBytes = 1_048_576
    static let maximumRequestBytes = 1_048_576
    static let maximumOptions = 256
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
        guard let options = request["options"] as? [[String: Any]], !options.isEmpty,
              options.count <= Self.maximumOptions else { throw .question }
        let offered = options.compactMap { $0["optionId"] as? String }
        guard offered.count == options.count, Set(offered.map { Data($0.utf8) }).count == offered.count,
              offered.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\u{0}") }) else { throw .question }
        guard options.contains(where: { $0["kind"] as? String == "allow_once"
            && ($0["optionId"] as? String).map { Self.equalBytes($0, option) } == true }) else { throw .option }
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
            guard let key = item[codex ? "id" : "prompt"] as? String, !key.isEmpty,
                  key.utf8.count <= AcpmuxPaneMethods.maximumAnswerBytes, seen.insert(Data(key.utf8)).inserted,
                  let value = answers.first(where: { equalBytes($0.key, key) })?.value else { return false }
            let labels: [String]
            if codex {
                guard let value = value as? [String: Any], Set(value.keys) == ["answers"],
                      let list = value["answers"] as? [String],
                      (1...AcpmuxPaneMethods.maximumAnswerListStrings).contains(list.count),
                      item["multiSelect"] as? Bool == true || list.count == 1 else { return false }
                labels = list
            } else {
                guard let text = value as? String else { return false }
                labels = [text]
            }
            guard labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= AcpmuxPaneMethods.maximumAnswerBytes }) else { return false }
            if item["allowsOther"] as? Bool != true {
                let options = item["options"] as? [[String: Any]] ?? []
                let allowed = options.compactMap { $0["label"] as? String }
                let picked = !codex && item["multiSelect"] as? Bool == true
                    ? labels[0].components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    : labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                // Match the owner's choice-only validation, including distinct multi choices.
                guard Set(picked.map { Data($0.utf8) }).count == picked.count,
                      picked.allSatisfy({ picked in allowed.contains(where: { equalBytes($0, picked) }) }) else { return false }
            }
        }
        return true
    }

    /// acpmux hub/questions.rs check_annotations: only the real Claude AskUserQuestion reads
    /// these. Previews match its original native tool input after trimming; notes are bounded.
    private static func validAnnotations(_ raw: Any, request: [String: Any], items: [[String: Any]], harness: String) -> Bool {
        guard harness == "claude", let tool = request["toolCall"] as? [String: Any],
              let meta = tool["_meta"] as? [String: Any],
              (meta["claude"] as? [String: Any])?["tool"] as? String == "AskUserQuestion",
              let originals = (tool["rawInput"] as? [String: Any])?["questions"] as? [[String: Any]],
              let annotations = raw as? [String: Any],
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

    private static func equalBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}
