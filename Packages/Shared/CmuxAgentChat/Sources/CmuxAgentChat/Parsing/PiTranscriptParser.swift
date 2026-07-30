import Foundation

/// Converts Pi and OMP version 3 session JSONL lines into ``ChatMessage`` values.
///
/// Version 3 stores every visible turn as a `message` entry whose nested role is
/// `user`, `assistant`, `developer`, `system`, or `toolResult`. Tool results can
/// arrive in a later tailing batch; pass the returned ``ChatTranscriptParseState``
/// into the next call so the original running tool row is updated in place.
public struct PiTranscriptParser: Sendable {
    private static let summaryArgumentKeys = [
        "path", "file_path", "pattern", "command", "query", "url",
        "description", "prompt", "name",
    ]

    private let budget = TranscriptTextBudget()
    private let timestamps = TranscriptTimestampParser()
    private let referencedPaths = ChatToolReferencedPathExtractor()
    private let artifactText = ChatArtifactTextReferenceExtractor()

    /// Creates a Pi/OMP transcript parser.
    public init() {}

    /// Parses a contiguous run of version 3 JSONL lines into chat messages.
    ///
    /// - Parameters:
    ///   - lines: The raw JSONL lines, one transcript line each.
    ///   - startingSeq: The absolute line index of the first input line;
    ///     each parsed message gets `seq == startingSeq + lineOffset`.
    ///   - state: Carry-over state from the previous parse call.
    /// - Returns: New messages, updates to earlier tool rows, and carry-over state.
    public func parse(
        lines: some Sequence<String>,
        startingSeq: Int,
        state: ChatTranscriptParseState = ChatTranscriptParseState()
    ) -> ChatTranscriptParseResult {
        var assembler = TranscriptBatchAssembler(state: state, budget: budget)
        var lastTimestamp = state.lastTimestamp

        for (offset, line) in lines.enumerated() {
            let seq = startingSeq + offset
            guard let root = TranscriptJSONValue(jsonLine: line), root.object != nil else {
                continue
            }
            if let stamped = timestamps.date(from: root["timestamp"]?.string) {
                lastTimestamp = stamped
            }
            let lineTimestamp = lastTimestamp ?? Date(timeIntervalSince1970: 0)

            switch root["type"]?.string {
            case "session":
                appendSession(root, seq: seq, timestamp: lineTimestamp, into: &assembler)
            case "message":
                appendMessage(
                    root,
                    seq: seq,
                    fallbackTimestamp: lineTimestamp,
                    lastTimestamp: &lastTimestamp,
                    into: &assembler
                )
            default:
                continue
            }
        }

        return assembler.result(lastTimestamp: lastTimestamp)
    }

    private func appendSession(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard root["version"]?.int == 3 else { return }
        let id = root["id"]?.string ?? "line-\(seq)"
        assembler.append(ChatMessage(
            id: id,
            seq: seq,
            role: .system,
            timestamp: timestamp,
            kind: .status(ChatStatusTransition(
                event: .sessionStarted,
                detail: Self.nonEmpty(root["cwd"]?.string)
            ))
        ))
    }

    private func appendMessage(
        _ root: TranscriptJSONValue,
        seq: Int,
        fallbackTimestamp: Date,
        lastTimestamp: inout Date?,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let message = root["message"], message.object != nil,
              let role = message["role"]?.string else { return }
        if role == "user", message["synthetic"]?.bool == true || root["synthetic"]?.bool == true {
            return
        }
        let timestamp: Date
        if let milliseconds = message["timestamp"]?.double {
            timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            lastTimestamp = timestamp
        } else {
            timestamp = fallbackTimestamp
        }
        let lineID = root["id"]?.string ?? "line-\(seq)"

        switch role {
        case "user":
            appendProseBlocks(
                message["content"], lineID: lineID, role: .user,
                seq: seq, timestamp: timestamp, into: &assembler
            )
        case "assistant":
            appendAssistantBlocks(
                message["content"], lineID: lineID,
                seq: seq, timestamp: timestamp, into: &assembler
            )
        case "developer", "system":
            appendProseBlocks(
                message["content"], lineID: lineID, role: .system,
                seq: seq, timestamp: timestamp, into: &assembler
            )
        case "toolResult":
            resolveToolResult(message, seq: seq, into: &assembler)
        default:
            return
        }
    }

    private func appendProseBlocks(
        _ content: TranscriptJSONValue?,
        lineID: String,
        role: ChatRole,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        var emitted = 0
        if let text = content?.string {
            appendProse(
                text, lineID: lineID, emitted: &emitted, role: role,
                seq: seq, timestamp: timestamp, into: &assembler
            )
            return
        }
        for block in content?.array ?? [] where block["type"]?.string == "text" {
            appendProse(
                block["text"]?.string ?? "", lineID: lineID, emitted: &emitted,
                role: role, seq: seq, timestamp: timestamp, into: &assembler
            )
        }
    }

    private func appendAssistantBlocks(
        _ content: TranscriptJSONValue?,
        lineID: String,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        var emitted = 0
        if let text = content?.string {
            appendProse(
                text, lineID: lineID, emitted: &emitted, role: .agent,
                seq: seq, timestamp: timestamp, into: &assembler
            )
            return
        }
        for block in content?.array ?? [] {
            switch block["type"]?.string {
            case "text":
                appendProse(
                    block["text"]?.string ?? "", lineID: lineID, emitted: &emitted,
                    role: .agent, seq: seq, timestamp: timestamp, into: &assembler
                )
            case "thinking":
                appendThought(
                    block["thinking"]?.string ?? "", lineID: lineID, emitted: &emitted,
                    seq: seq, timestamp: timestamp, into: &assembler
                )
            case "toolCall":
                appendToolCall(
                    block, lineID: lineID, emitted: &emitted,
                    seq: seq, timestamp: timestamp, into: &assembler
                )
            default:
                continue
            }
        }
    }

    private func appendProse(
        _ text: String,
        lineID: String,
        emitted: inout Int,
        role: ChatRole,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.appendArtifactReferences(paths: artifactText.paths(in: text), seq: seq)
        assembler.append(ChatMessage(
            id: Self.blockID(lineID: lineID, emitted: emitted),
            seq: seq,
            role: role,
            timestamp: timestamp,
            kind: .prose(ChatProse(text: budget.body(text)))
        ))
        emitted += 1
    }

    private func appendThought(
        _ text: String,
        lineID: String,
        emitted: inout Int,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.appendArtifactReferences(paths: artifactText.paths(in: text), seq: seq)
        assembler.append(ChatMessage(
            id: Self.blockID(lineID: lineID, emitted: emitted),
            seq: seq,
            role: .agent,
            timestamp: timestamp,
            kind: .thought(ChatThought(text: budget.body(text)))
        ))
        emitted += 1
    }

    private func appendToolCall(
        _ block: TranscriptJSONValue,
        lineID: String,
        emitted: inout Int,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let toolName = Self.nonEmpty(block["name"]?.string) else { return }
        let callID = Self.nonEmpty(block["id"]?.string)
        let arguments = block["arguments"]
        var summary = toolName
        if let arguments {
            for key in Self.summaryArgumentKeys {
                if let value = Self.nonEmpty(arguments[key]?.string) {
                    summary = "\(toolName) \(budget.summaryArgument(value))"
                    break
                }
            }
        }
        let message = ChatMessage(
            id: Self.blockID(lineID: lineID, emitted: emitted),
            seq: seq,
            role: .agent,
            timestamp: timestamp,
            kind: .toolUse(ChatToolUse(
                toolName: toolName,
                summary: summary,
                inputDetail: arguments.map { budget.inputDetail($0.compactJSONString()) },
                referencedPaths: referencedPaths.referencedPaths(in: arguments)
            ))
        )
        assembler.append(message, pendingKey: callID)
        emitted += 1
    }

    private func resolveToolResult(
        _ message: TranscriptJSONValue,
        seq: Int,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = Self.nonEmpty(message["toolCallId"]?.string) else { return }
        let output = Self.resultText(from: message["content"])
        if let output {
            assembler.appendArtifactReferences(paths: artifactText.paths(in: output), seq: seq)
        }
        assembler.resolve(
            key: callID,
            completion: TranscriptToolCompletion(
                output: output,
                isError: message["isError"]?.bool ?? false
            )
        )
    }

    private static func resultText(from content: TranscriptJSONValue?) -> String? {
        if let text = content?.string { return text }
        let texts = (content?.array ?? []).compactMap { block -> String? in
            guard block["type"]?.string == "text" else { return nil }
            return block["text"]?.string
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func blockID(lineID: String, emitted: Int) -> String {
        emitted == 0 ? lineID : "\(lineID)#\(emitted)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
