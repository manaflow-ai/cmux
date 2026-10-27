import Foundation

/// Finds the user's own `/effort` and `/model` changes in a Claude transcript.
///
/// Claude Code records a local command as a `"type":"user"` entry whose `message.content` holds
/// what the command printed between `<local-command-stdout>` and `</local-command-stdout>`, and
/// every entry carries an ISO 8601 `timestamp` such as `2026-10-27T04:56:09.401Z`. A cancelled
/// command prints none of the ``changeMarkers``.
public enum ClaudeTranscriptLocalCommandProbe {
    /// What Claude Code prints after changing the effort or the model, current wording first.
    public static let changeMarkers = [
        "Set effort level to",
        "Effort level set to",
        "Set model to",
        "Model set to",
    ]

    private static let stdoutOpenTag = "<local-command-stdout>"
    private static let stdoutCloseTag = "</local-command-stdout>"

    /// The timestamp of the newest effort or model change recorded later than `after`, or `nil`.
    ///
    /// Reads at most the last `maxTailBytes` of the file and only complete lines in it: a line
    /// the tail starts inside of, and one still being written, are skipped.
    ///
    /// - Throws: When the transcript cannot be opened or read.
    public static func lastEffortOrModelChange(
        transcriptPath: String,
        after: Date,
        maxTailBytes: Int = 512 * 1024
    ) throws -> Date? {
        let tail = try completeLines(ofTailOf: transcriptPath, maxBytes: maxTailBytes)
        let quickMarker = Data(stdoutOpenTag.utf8)
        let timestamps = TimestampParser()
        var newest: Date?
        for line in tail where line.range(of: quickMarker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "user",
                  let date = timestamps.date(object["timestamp"]),
                  date > after,
                  newest.map({ date > $0 }) ?? true,
                  let message = object["message"] as? [String: Any],
                  reportsAChange(content: message["content"])
            else { continue }
            newest = date
        }
        return newest
    }

    /// Whether the command output in `content` (a string or text blocks) reports a change.
    private static func reportsAChange(content: Any?) -> Bool {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return false
        }
        return stdoutSegments(in: text).contains { segment in
            changeMarkers.contains { segment.contains($0) }
        }
    }

    /// The text between each stdout open tag and its close tag, or the end of `text`.
    private static func stdoutSegments(in text: String) -> [Substring] {
        var segments: [Substring] = []
        var rest = text[...]
        while let open = rest.range(of: stdoutOpenTag) {
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: stdoutCloseTag) {
                segments.append(afterOpen[..<close.lowerBound])
                rest = afterOpen[close.upperBound...]
            } else {
                segments.append(afterOpen)
                break
            }
        }
        return segments
    }

    /// The complete lines among the file's last `maxBytes` bytes.
    private static func completeLines(ofTailOf path: String, maxBytes: Int) throws -> [Data.SubSequence] {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let tailBytes = UInt64(max(maxBytes, 0))
        let start = size > tailBytes ? size - tailBytes : 0
        // One byte before the tail tells whether it starts on a line boundary.
        try handle.seek(toOffset: start > 0 ? start - 1 : 0)
        var data = try handle.readToEnd() ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 10) else { return [] }
            data = data[data.index(after: newline)...]
        }
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    /// Reads the transcript's ISO 8601 timestamps, with or without fractional seconds.
    private struct TimestampParser {
        private let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private let whole: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        func date(_ value: Any?) -> Date? {
            guard let string = value as? String else { return nil }
            return fractional.date(from: string) ?? whole.date(from: string)
        }
    }
}
