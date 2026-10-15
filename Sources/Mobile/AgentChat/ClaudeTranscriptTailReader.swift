import Foundation

/// Reads only the tail of a Claude Code transcript (`~/.claude/projects/<dir>/<sessionId>.jsonl`)
/// and returns the newest session metadata lines Claude writes there:
///
/// - `{"type":"ai-title","aiTitle":"…","sessionId":"…"}` — Claude's own title for the conversation
/// - `{"type":"last-prompt","lastPrompt":"…","leafUuid":"…","sessionId":"…"}` — the last user prompt
///
/// Transcripts grow to hundreds of megabytes, so the reader seeks to the last
/// `maxBytes`, drops the partial first line, and scans the remaining lines
/// newest-first. `ClaudeTranscriptParser` deliberately skips these line types;
/// this reader is the one place that surfaces them. Never call it on the main
/// actor: it does synchronous file IO.
struct ClaudeTranscriptTailReader: Sendable {
    /// The metadata found in the tail. Both fields are nil when the tail holds
    /// no metadata line; `read` returns nil only when the file is unreadable.
    struct Tail: Equatable, Sendable {
        let aiTitle: String?
        let lastPrompt: String?
    }

    /// How many bytes from the end of the file are inspected.
    var maxBytes: Int = 65_536

    init(maxBytes: Int = 65_536) {
        self.maxBytes = max(1, maxBytes)
    }

    /// Reads the tail of the transcript at `path`.
    ///
    /// - Returns: nil when the file cannot be opened or read; otherwise the
    ///   newest `ai-title` / `last-prompt` values found within the tail.
    func read(path: String) -> Tail? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let window = UInt64(maxBytes)
            let readStart = size > window ? size - window : 0
            try handle.seek(toOffset: readStart)
            guard var data = try handle.readToEnd() else {
                return Tail(aiTitle: nil, lastPrompt: nil)
            }
            if readStart > 0, let newline = data.firstIndex(of: 0x0A) {
                // The first line of a mid-file window is almost always cut in
                // half; drop it rather than feed half a JSON object to the parser.
                data.removeSubrange(data.startIndex...newline)
            }
            let text = String(decoding: data, as: UTF8.self)
            return Self.tail(fromLines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        } catch {
            return nil
        }
    }

    /// Pure scan of transcript lines (oldest first) for the newest metadata values.
    static func tail(fromLines lines: [String]) -> Tail {
        var aiTitle: String?
        var lastPrompt: String?
        for line in lines.reversed() {
            if aiTitle != nil, lastPrompt != nil { break }
            let wantsTitle = aiTitle == nil && line.contains("\"ai-title\"")
            let wantsPrompt = lastPrompt == nil && line.contains("\"last-prompt\"")
            guard wantsTitle || wantsPrompt else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }
            switch type {
            case "ai-title" where aiTitle == nil:
                aiTitle = Self.normalized(object["aiTitle"] as? String)
            case "last-prompt" where lastPrompt == nil:
                lastPrompt = Self.normalized(object["lastPrompt"] as? String)
            default:
                continue
            }
        }
        return Tail(aiTitle: aiTitle, lastPrompt: lastPrompt)
    }

    /// Collapses whitespace runs (including newlines) to single spaces and trims;
    /// empty results become nil so callers can fall back.
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
