import Foundation

/// Maps provider-specific stop payloads into the shared foreground state.
/// Reads at most the tail of a Codex transcript and ignores free-form messages
/// to avoid treating prose about an interruption as an actual interrupted turn.
struct AgentStopStateAdapter: Sendable {
    private let maximumTranscriptBytes: UInt64 = 512 * 1024

    func isInterrupted(
        provider: String,
        input: ClaudeHookParsedInput,
        transcriptPath: String? = nil
    ) -> Bool {
        if structuralSignals(input).contains(where: Self.isInterruptionSignal) {
            return true
        }
        guard provider.lowercased() == "codex",
              let path = normalized(transcriptPath ?? input.transcriptPath) else {
            return false
        }
        return codexTurnWasAborted(path: path, turnId: normalized(input.turnId))
    }

    private func structuralSignals(_ input: ClaudeHookParsedInput) -> [String] {
        let keys = [
            "hook_event_name", "hookEventName", "event", "event_name", "type",
            "kind", "reason", "stop_reason", "stopReason", "terminationReason", "status",
        ]
        let objects = [
            input.rawObject,
            input.object,
            input.rawObject?["data"] as? [String: Any],
            input.object?["data"] as? [String: Any],
        ]
        return objects.compactMap { $0 }.flatMap { object in
            keys.compactMap { object[$0] as? String }
        }
    }

    private func codexTurnWasAborted(path: String, turnId: String?) -> Bool {
        guard let data = readTail(path: path),
              let text = String(data: data, encoding: .utf8) else { return false }
        var lastTerminalEvent: String?
        var currentTurnId: String?
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let objectType = object["type"] as? String else { continue }
            if objectType == "turn_context",
               let payload = object["payload"] as? [String: Any] {
                currentTurnId = string(payload, keys: ["turn_id", "turnId"])
                continue
            }
            guard objectType == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let event = payload["type"] as? String else { continue }
            if event == "task_started" {
                currentTurnId = string(payload, keys: ["turn_id", "turnId"])
                continue
            }
            guard ["task_complete", "turn_complete", "turn_aborted"].contains(event) else { continue }
            let eventTurnId = string(payload, keys: ["turn_id", "turnId"]) ?? currentTurnId
            if turnId == nil || eventTurnId == turnId { lastTerminalEvent = event }
        }
        return lastTerminalEvent == "turn_aborted"
    }

    private func readTail(path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: NSString(string: path).expandingTildeInPath) else {
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > maximumTranscriptBytes ? size - maximumTranscriptBytes : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        if offset == 0 { return data }
        guard let firstNewline = data.firstIndex(of: 0x0A) else { return Data() }
        return data.suffix(from: data.index(after: firstNewline))
    }

    private func string(_ object: [String: Any], keys: [String]) -> String? {
        keys.compactMap { normalized(object[$0] as? String) }.first
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func isInterruptionSignal(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return normalized == "interrupt"
            || normalized == "interrupted"
            || normalized == "abort"
            || normalized == "aborted"
            || normalized == "turn_aborted"
            || normalized == "cancelled"
            || normalized == "canceled"
            || normalized == "user_cancelled"
            || normalized == "user_canceled"
    }
}
