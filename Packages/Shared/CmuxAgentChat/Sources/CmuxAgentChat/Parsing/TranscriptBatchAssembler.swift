import Foundation

/// Accumulates the messages of one parse call and routes tool results to
/// the right place: in-batch messages are completed in place, messages from
/// earlier calls are re-emitted as updates.
struct TranscriptBatchAssembler {
    private var messages: [ChatMessage] = []
    private var updatedMessages: [ChatMessage] = []
    private var artifactReferences: [ChatArtifactTranscriptReference] = []
    private var pending: [String: [ChatMessage]]
    private var pendingArtifactMutations: [String: [ChatArtifactTranscriptReference]]
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
        self.pendingArtifactMutations = state.pendingArtifactMutations
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

    /// Appends paths captured from raw transcript text or artifacts-only rows.
    ///
    /// - Parameters:
    ///   - paths: Path tokens in display order.
    ///   - provenance: Provenance established by the originating channel.
    ///   - seq: Sequence of the containing transcript line.
    mutating func appendArtifactReferences(
        paths: [String],
        provenance: ChatArtifactProvenance = .referenced,
        seq: Int
    ) {
        artifactReferences.append(contentsOf: paths.map {
            ChatArtifactTranscriptReference(path: $0, provenance: provenance, seq: seq)
        })
    }

    /// Registers sidechain mutation targets without exposing sidechain messages.
    mutating func registerArtifactMutation(paths: [String], pendingKey: String, seq: Int) {
        guard !paths.isEmpty else { return }
        pendingArtifactMutations[pendingKey] = paths.map {
            ChatArtifactTranscriptReference(path: $0, provenance: .referenced, seq: seq)
        }
    }

    /// Pairs a tool result with its pending invocation, if registered.
    ///
    /// - Parameters:
    ///   - key: The tool call identifier from the result line.
    ///   - completion: The observed result.
    mutating func resolve(
        key: String,
        completion: TranscriptToolCompletion,
        resultSeq: Int
    ) {
        if let references = pendingArtifactMutations.removeValue(forKey: key),
           completion.authorizesArtifactMutation {
            appendArtifactReferences(
                paths: references.map(\.path),
                provenance: .created,
                seq: resultSeq
            )
        }
        guard let pendingMessages = pending.removeValue(forKey: key) else { return }
        // Apply to every message registered under this call id. For
        // questions, `completion.applied` resolves each by its own prompt,
        // so multi-question cards each get their correct answer.
        for pendingMessage in pendingMessages {
            if completion.authorizesArtifactMutation {
                appendArtifactReferences(
                    paths: mutationPaths(in: pendingMessage),
                    provenance: .created,
                    seq: resultSeq
                )
            }
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
            artifactReferences: artifactReferences,
            state: ChatTranscriptParseState(
                pendingToolUses: Self.bounded(pending),
                pendingArtifactMutations: Self.bounded(pendingArtifactMutations),
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

    private static func bounded(
        _ pending: [String: [ChatArtifactTranscriptReference]]
    ) -> [String: [ChatArtifactTranscriptReference]] {
        guard pending.count > maxPendingToolUses else { return pending }
        let newestFirst = pending.sorted { lhs, rhs in
            (lhs.value.map(\.seq).max() ?? 0) > (rhs.value.map(\.seq).max() ?? 0)
        }
        return Dictionary(
            uniqueKeysWithValues: newestFirst.prefix(maxPendingToolUses).map { ($0.key, $0.value) }
        )
    }

    private func mutationPaths(in message: ChatMessage) -> [String] {
        switch message.kind {
        case .fileEdit(let edit):
            return [edit.filePath]
        case .toolUse(let toolUse):
            return toolUse.artifactMutationPaths
        case .terminal(let terminal):
            return ShellArtifactMutationPathDetector()
                .pathsAttributedToSuccessfulCommand(in: terminal.command)
        case .prose, .thought, .permissionRequest, .question,
             .status, .attachment, .unsupported:
            return []
        }
    }
}
