import Foundation

/// Accumulates the messages of one parse call and routes tool results to
/// the right place: in-batch messages are completed in place, messages from
/// earlier calls are re-emitted as updates.
struct TranscriptBatchAssembler {
    private var messages: [ChatMessage] = []
    private var updatedMessages: [ChatMessage] = []
    private var pending: [String: [ChatMessage]]
    private var batchIndexByMessageID: [String: Int] = [:]
    private let budget: TranscriptTextBudget

    /// Upper bound on tool invocations carried across parse calls awaiting a
    /// result. A `tool_use` whose `tool_result` never arrives (interrupted or
    /// crashed tool, malformed result line) would otherwise accumulate in
    /// `pending` for the life of the tailer. Capping to the most-recent N (by
    /// seq) bounds the carried state; dropping the oldest unresolved calls only
    /// means an extremely-late result (>N tool calls later) won't back-patch.
    static let maxPendingToolUses = 256

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
            // A single tool call can register multiple messages (a
            // multi-question AskUserQuestion emits one card per question);
            // its result must resolve all of them, so group by call id.
            pending[pendingKey, default: []].append(message)
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
        guard let pendingMessages = pending.removeValue(forKey: key) else { return }
        // Apply to every message registered under this call id. For
        // questions, `completion.applied` resolves each by its own prompt,
        // so multi-question cards each get their correct answer.
        for pendingMessage in pendingMessages {
            guard let completed = completion.applied(to: pendingMessage, budget: budget) else {
                continue
            }
            if let index = batchIndexByMessageID[completed.id] {
                messages[index] = completed
            } else {
                updatedMessages.append(completed)
            }
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
                pendingToolUses: Self.bounded(pending),
                lastTimestamp: lastTimestamp
            )
        )
    }

    /// Caps carried pending tool uses to the most-recent ``maxPendingToolUses``
    /// by their newest message seq, evicting the oldest unresolved calls.
    private static func bounded(_ pending: [String: [ChatMessage]]) -> [String: [ChatMessage]] {
        guard pending.count > maxPendingToolUses else { return pending }
        let newestFirst = pending.sorted { lhs, rhs in
            (lhs.value.map(\.seq).max() ?? 0) > (rhs.value.map(\.seq).max() ?? 0)
        }
        return Dictionary(
            uniqueKeysWithValues: newestFirst.prefix(maxPendingToolUses).map { ($0.key, $0.value) }
        )
    }
}
