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
    /// Bound unresolved sidechain mutation references by both entry count and
    /// UTF-8 bytes; a single malformed tool call must not retain an unbounded
    /// path array across incremental parse calls.
    static let maxPendingArtifactMutationReferences = 1_024
    static let maxPendingArtifactMutationBytes = 256 * 1_024
    static let maxArtifactMutationReferencesPerCall = 256
    /// Limit one registration so a single malformed tool call cannot consume
    /// the entire cross-call mutation budget.
    static let maxArtifactMutationBytesPerCall = 64 * 1_024
    static let maxArtifactMutationPathBytes = 4_096

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
        guard !paths.isEmpty, !pendingKey.isEmpty else { return }
        var references: [ChatArtifactTranscriptReference] = []
        references.reserveCapacity(min(paths.count, Self.maxArtifactMutationReferencesPerCall))
        var bytes = 0
        for path in paths {
            guard references.count < Self.maxArtifactMutationReferencesPerCall,
                  bytes < Self.maxArtifactMutationBytesPerCall else {
                break
            }
            guard !path.isEmpty else { continue }
            let pathBytes = path.utf8.count
            guard pathBytes <= Self.maxArtifactMutationPathBytes else { continue }
            guard pathBytes <= Self.maxArtifactMutationBytesPerCall - bytes else {
                break
            }
            references.append(ChatArtifactTranscriptReference(
                path: path,
                provenance: .referenced,
                seq: seq
            ))
            bytes += pathBytes
        }
        guard !references.isEmpty else { return }
        pendingArtifactMutations[pendingKey] = references
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
                pendingToolUses: bounded(pending),
                pendingArtifactMutations: bounded(pendingArtifactMutations),
                lastTimestamp: lastTimestamp
            )
        )
    }

    /// Caps carried pending tool uses to the most-recent ``maxPendingToolUses``
    /// by their newest message seq, evicting the oldest unresolved calls.
    private func bounded(_ pending: [String: [ChatMessage]]) -> [String: [ChatMessage]] {
        guard pending.count > Self.maxPendingToolUses else { return pending }
        let newestFirst = pending.sorted { lhs, rhs in
            (lhs.value.map(\.seq).max() ?? 0) > (rhs.value.map(\.seq).max() ?? 0)
        }
        return Dictionary(
            uniqueKeysWithValues: newestFirst.prefix(Self.maxPendingToolUses).map { ($0.key, $0.value) }
        )
    }

    private func bounded(
        _ pending: [String: [ChatArtifactTranscriptReference]]
    ) -> [String: [ChatArtifactTranscriptReference]] {
        let newestFirst = pending.sorted { lhs, rhs in
            (lhs.value.map(\.seq).max() ?? 0) > (rhs.value.map(\.seq).max() ?? 0)
        }
        var bounded: [String: [ChatArtifactTranscriptReference]] = [:]
        var referenceCount = 0
        var byteCount = 0
        for (key, references) in newestFirst {
            guard referenceCount < Self.maxPendingArtifactMutationReferences,
                  byteCount < Self.maxPendingArtifactMutationBytes else {
                break
            }
            var retained: [ChatArtifactTranscriptReference] = []
            for reference in references {
                guard !reference.path.isEmpty else { continue }
                let bytes = reference.path.utf8.count
                guard bytes <= Self.maxArtifactMutationPathBytes else { continue }
                guard referenceCount < Self.maxPendingArtifactMutationReferences else {
                    break
                }
                guard bytes <= Self.maxPendingArtifactMutationBytes - byteCount else {
                    break
                }
                retained.append(reference)
                referenceCount += 1
                byteCount += bytes
            }
            if !retained.isEmpty {
                bounded[key] = retained
            }
        }
        return bounded
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
