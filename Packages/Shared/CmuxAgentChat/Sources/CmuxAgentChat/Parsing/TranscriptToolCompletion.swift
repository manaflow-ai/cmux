import Foundation

/// A tool result observed in the transcript, applied to the pending
/// running-state message that the matching tool invocation produced.
struct TranscriptToolCompletion: Sendable {
    /// The result text, already extracted from the transcript shape.
    let output: String?

    /// Whether the transcript flagged the result as an error, when it carried
    /// an explicit flag.
    let isError: Bool?

    /// The exit code, when one was parseable from the result.
    let exitCode: Int?

    /// Wall-clock duration in seconds, when one was parseable.
    let durationSeconds: Double?

    /// Whether source-specific positive evidence authorizes mutation provenance.
    let authorizesArtifactMutation: Bool

    /// Whether the provider supplied positive completion evidence for display.
    let hasPositiveSuccessEvidence: Bool

    /// Returns whether a tool result provides enough positive evidence to
    /// authorize a file mutation.
    ///
    /// Claude must carry an explicit `is_error: false` flag before its output
    /// can authorize a mutation. Textual exit-code headers are display data,
    /// not provider-authenticated success evidence. Empty or missing output
    /// still fails closed when no exit code is available.
    static func authorizesMutation(
        output: String?,
        isError: Bool?,
        exitCode: Int?
    ) -> Bool {
        if let exitCode {
            return exitCode == 0 && isError == false
        }
        guard isError == false else { return false }
        guard let output,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !reportsFailureWithoutExitStatus(output)
    }

    /// Whether the result proves the pending invocation completed successfully.
    var succeeded: Bool {
        guard isError != true else { return false }
        if let exitCode { return exitCode == 0 }
        if reportsFailureWithoutExitStatus { return false }
        if isError == false { return true }
        return hasPositiveSuccessEvidence
    }

    /// Creates a completion.
    ///
    /// - Parameters:
    ///   - output: The extracted result text.
    ///   - isError: Whether the result was explicitly flagged as an error.
    ///   - exitCode: The parsed exit code, when available.
    ///   - durationSeconds: The parsed duration, when available.
    ///   - authorizesArtifactMutation: Whether the source proved a mutation succeeded.
    init(
        output: String?,
        isError: Bool?,
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        authorizesArtifactMutation: Bool,
        hasPositiveSuccessEvidence: Bool = false
    ) {
        self.output = output
        self.isError = isError
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.authorizesArtifactMutation = authorizesArtifactMutation
        self.hasPositiveSuccessEvidence = hasPositiveSuccessEvidence
    }

    /// Produces the completed copy of a pending tool message.
    ///
    /// - Parameters:
    ///   - message: The pending message in its running form.
    ///   - budget: The text budget for stored output.
    /// - Returns: The completed message, or `nil` when the result does not
    ///   change how the message renders (file edits, unanswered questions).
    func applied(to message: ChatMessage, budget: TranscriptTextBudget) -> ChatMessage? {
        switch message.kind {
        case .terminal(let capture):
            let completed = ChatTerminalCapture(
                command: capture.command,
                output: output.map { budget.body($0) },
                exitCode: exitCode ?? (succeeded ? 0 : 1),
                durationSeconds: durationSeconds,
                isRunning: false
            )
            return message.replacingKind(.terminal(completed))
        case .toolUse(let toolUse):
            let completed = ChatToolUse(
                toolName: toolUse.toolName,
                summary: toolUse.summary,
                inputDetail: toolUse.inputDetail,
                output: output.map { budget.body($0) },
                status: succeeded ? .succeeded : .failed,
                referencedPaths: toolUse.referencedPaths,
                artifactMutationAuthorized: toolUse.artifactMutationPaths.isEmpty
                    ? nil
                    : authorizesArtifactMutation
            )
            return message.replacingKind(.toolUse(completed))
        case .question(let question):
            // Codex keys answers by question id, so a multi-question call
            // resolves each card to its own answer; Claude keys by prompt.
            let answer: String?
            if let questionID = question.questionID {
                answer = self.answer(forCodexQuestionID: questionID)
            } else {
                answer = self.answer(forPrompt: question.prompt)
            }
            guard let answer else { return nil }
            let answered = ChatQuestion(
                prompt: question.prompt,
                options: question.options,
                selectedOptionLabel: answer,
                questionID: question.questionID
            )
            return message.replacingKind(.question(answered))
        default:
            return nil
        }
    }

    /// Extracts the chosen answer for a question prompt.
    ///
    /// Handles two formats:
    /// - Claude: `Your questions have been answered: "Q"="A"...`.
    /// - Codex `request_user_input`: a JSON output
    ///   `{"answers":{"<id>":{"answers":["<label>"]}}}`. Codex keys answers by
    ///   question id (not prompt), so for the common single-question picker the
    ///   first non-empty answer is returned.
    ///
    /// - Parameter prompt: The question prompt to look up.
    /// - Returns: The answer text, or `nil` when not extractable.
    private func answer(forPrompt prompt: String) -> String? {
        guard let output else { return nil }
        // Claude `"Q"="A"` format.
        let needle = "\"\(prompt)\"=\""
        if let start = output.range(of: needle) {
            let tail = output[start.upperBound...]
            if let end = tail.range(of: "\"") {
                let answer = String(tail[..<end.lowerBound])
                if !answer.isEmpty { return answer }
            }
        }
        // Codex JSON `{"answers":{<id>:{"answers":[<label>]}}}` format (fallback
        // for a codex question with no id: first non-empty answer).
        if let answers = codexAnswers(from: output) {
            for value in answers.values {
                if let labels = value["answers"] as? [String],
                   let first = labels.first(where: { !$0.isEmpty }) {
                    return first
                }
            }
        }
        return nil
    }

    /// The chosen answer for a specific Codex question id, from the
    /// `request_user_input` output `{"answers":{"<id>":{"answers":["<label>"]}}}`.
    /// Matching by id lets a multi-question call resolve each card correctly.
    private func answer(forCodexQuestionID id: String) -> String? {
        guard let output,
              let answers = codexAnswers(from: output),
              let entry = answers[id],
              let labels = entry["answers"] as? [String] else { return nil }
        return labels.first(where: { !$0.isEmpty })
    }

    /// Parses the `answers` object out of a Codex `request_user_input` output.
    private func codexAnswers(from output: String) -> [String: [String: Any]]? {
        guard output.contains("\"answers\""),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else { return nil }
        return answers.compactMapValues { $0 as? [String: Any] }
    }

    /// Some tools can report failure only in their text envelope.
    static func reportsFailureWithoutExitStatus(_ output: String) -> Bool {
        let prefix = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(400)
            .lowercased()
        let lines = prefix.split(whereSeparator: \.isNewline)
        // Inspect only the envelope header and its first payload line. Deeper
        // lines are often arbitrary grep/read output and must not turn a
        // successful tool into a failure merely because they contain words
        // such as "error" or "failed".
        return lines.prefix(2).contains { Self.isFailureEnvelopeLine($0) }
    }

    private static func isFailureEnvelopeLine(_ line: Substring) -> Bool {
        line.hasPrefix("script failed")
            || line.hasPrefix("tool failed")
            || line.hasPrefix("apply_patch verification failed")
            || line.hasPrefix("error:")
            || line.hasPrefix("permission denied")
            || line.hasPrefix("access denied")
            || line.hasPrefix("operation not permitted")
            || line == "failed"
            || line.hasPrefix("failed:")
            || line.hasPrefix("failed to ")
            || line.hasPrefix("patch failed")
            || line == "failure"
            || line.hasPrefix("failure:")
            || line == "unable"
            || line.hasPrefix("unable to ")
            || line == "exception"
            || line.hasPrefix("exception:")
            || line == "no matches"
            || line.hasPrefix("no matches ")
    }

    private var reportsFailureWithoutExitStatus: Bool {
        guard let output else { return false }
        return Self.reportsFailureWithoutExitStatus(output)
    }
}

extension ChatMessage {
    /// Copies the message with a different payload, keeping identity,
    /// position, author, and timestamp.
    ///
    /// - Parameter kind: The replacement payload.
    /// - Returns: The copied message.
    func replacingKind(_ kind: ChatMessageKind) -> ChatMessage {
        ChatMessage(id: id, seq: seq, role: role, timestamp: timestamp, kind: kind)
    }
}
