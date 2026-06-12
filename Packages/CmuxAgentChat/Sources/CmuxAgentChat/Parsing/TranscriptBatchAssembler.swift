import Foundation

/// Accumulates the messages of one parse call and routes tool results to
/// the right place: in-batch messages are completed in place, messages from
/// earlier calls are re-emitted as updates.
struct TranscriptBatchAssembler {
    private var messages: [ChatMessage] = []
    private var updatedMessages: [ChatMessage] = []
    private var pending: [String: ChatMessage]
    private var batchIndexByMessageID: [String: Int] = [:]
    private let budget: TranscriptTextBudget

    /// Creates an assembler seeded with carried-over pending tool uses.
    ///
    /// - Parameters:
    ///   - state: The carry-over state from the previous parse call.
    ///   - budget: The text budget applied to completed outputs.
    init(state: ChatTranscriptParseState, budget: TranscriptTextBudget) {
        self.pending = state.pendingToolUses
        self.budget = budget
    }

    /// Appends a newly parsed message, optionally registering it as a tool
    /// invocation awaiting its result.
    ///
    /// - Parameters:
    ///   - message: The message to append.
    ///   - pendingKey: The tool call identifier to pair a later result by,
    ///     or `nil` for messages that never receive results.
    mutating func append(_ message: ChatMessage, pendingKey: String? = nil) {
        if let pendingKey {
            pending[pendingKey] = message
            batchIndexByMessageID[message.id] = messages.count
        }
        messages.append(message)
    }

    /// Pairs a tool result with its pending invocation, if registered.
    ///
    /// - Parameters:
    ///   - key: The tool call identifier from the result line.
    ///   - completion: The observed result.
    mutating func resolve(key: String, completion: TranscriptToolCompletion) {
        guard let pendingMessage = pending.removeValue(forKey: key) else { return }
        guard let completed = completion.applied(to: pendingMessage, budget: budget) else {
            return
        }
        if let index = batchIndexByMessageID[completed.id] {
            messages[index] = completed
        } else {
            updatedMessages.append(completed)
        }
    }

    /// Finalizes the batch into a parse result.
    ///
    /// - Parameter lastTimestamp: The last timestamp seen, carried forward.
    /// - Returns: The assembled parse result.
    func result(lastTimestamp: Date?) -> ChatTranscriptParseResult {
        ChatTranscriptParseResult(
            messages: messages,
            updatedMessages: updatedMessages,
            state: ChatTranscriptParseState(
                pendingToolUses: pending,
                lastTimestamp: lastTimestamp
            )
        )
    }
}
