import Foundation

/// Reads the latest user prompts from the end of an agent transcript, for
/// the compact-and-resume focus note.
///
/// Only the tail is read, so a long session costs the same as a short one.
/// Claude's compaction summary is written as a user line and is skipped.
struct AgentRecentPromptReader: Sendable {
    let agent: AgentTurnInterruptTarget
    /// How much of the transcript's end to read.
    var tailBytes = 1 << 20
    /// How many prompts to return at most.
    var limit = 5

    /// The latest prompts, oldest first, or none when the file can't be read.
    func prompts(transcriptURL: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty {
            // The first line was cut by the seek.
            lines.removeFirst()
        }
        var prompts: [String] = []
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let prompt = prompt(in: object) else { continue }
            // Codex writes each prompt twice (event and response item).
            if prompts.last == prompt { continue }
            prompts.append(prompt)
            if prompts.count == limit { break }
        }
        return prompts.reversed()
    }

    private func prompt(in object: [String: Any]) -> String? {
        switch agent {
        case .claudeCode:
            guard (object["isCompactSummary"] as? Bool) != true else { return nil }
            return VaultSessionCheckpoints.claudeEditablePromptText(from: object)
        case .codex:
            return VaultSessionCheckpoints.codexUserPromptText(from: object)
        }
    }
}
