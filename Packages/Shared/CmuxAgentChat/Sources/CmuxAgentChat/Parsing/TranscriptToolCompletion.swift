import Foundation

/// A tool result observed in the transcript, applied to the pending
/// running-state message that the matching tool invocation produced.
struct TranscriptToolCompletion: Sendable {
    /// The result text, already extracted from the transcript shape.
    let output: String?

    /// Whether the transcript flagged the result as an error.
    let isError: Bool

    /// The exit code, when one was parseable from the result.
    let exitCode: Int?

    /// Wall-clock duration in seconds, when one was parseable.
    let durationSeconds: Double?

    /// Creates a completion.
    ///
    /// - Parameters:
    ///   - output: The extracted result text.
    ///   - isError: Whether the result was flagged as an error.
    ///   - exitCode: The parsed exit code, when available.
    ///   - durationSeconds: The parsed duration, when available.
    init(
        output: String?,
        isError: Bool,
        exitCode: Int? = nil,
        durationSeconds: Double? = nil
    ) {
        self.output = output
        self.isError = isError
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
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
                exitCode: exitCode ?? (isError ? 1 : 0),
                durationSeconds: durationSeconds,
                isRunning: false
            )
            return message.replacingKind(.terminal(completed))
        case .toolUse(let toolUse):
            let failed = isError || (exitCode ?? 0) != 0
            let completed = ChatToolUse(
                toolName: toolUse.toolName,
                summary: toolUse.summary,
                inputDetail: toolUse.inputDetail,
                output: output.map { budget.body($0) },
                status: failed ? .failed : .succeeded,
                referencedPaths: toolUse.referencedPaths
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
