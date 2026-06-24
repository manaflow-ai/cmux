public import Foundation

/// Pure parsing helpers for the on-disk JSONL history records that the
/// registered-agent and Antigravity session loaders read.
///
/// Agent session history is stored as line-delimited JSON (`.jsonl`) whose
/// records deserialize into loosely-typed `[String: Any]` objects. This type owns
/// the field-name conventions and value-coercion math those loaders rely on: the
/// candidate key lists for cwd / session-id extraction, the Antigravity title
/// selection, the case-insensitive needle match across a record's
/// session-id/title/cwd, the millisecond-or-second timestamp normalization, plus
/// two filesystem helpers (a streaming case-insensitive substring scan over a
/// file, and the Pi `--encoded--path--` directory-name to working-directory
/// inference). The title and session-id extraction delegate the actual text
/// traversal to a constructor-injected ``AgentSessionFieldParser``.
///
/// Every method is a pure transform over its inputs (the filesystem helpers read
/// but never write), so a parser built from a default field parser is sufficient.
/// Mirrors the sibling ``AgentSessionFieldParser``: an instance value type with
/// instance methods and a constructor-injected collaborator rather than a
/// static-only utility namespace. The `SessionIndexStore` loaders construct one
/// and call its instance methods while projecting on-disk history JSON into
/// session metadata.
public struct AgentHistoryRecordParser {
    private let fieldParser: AgentSessionFieldParser

    /// Creates a parser.
    ///
    /// - Parameter fieldParser: The collaborator used for title and session-id
    ///   text extraction. Defaults to a fresh parser, which is stateless.
    public init(fieldParser: AgentSessionFieldParser = AgentSessionFieldParser()) {
        self.fieldParser = fieldParser
    }

    /// Candidate keys, tried in order, for a record's working directory.
    public func registeredJSONLCWDKeys() -> [String] {
        ["cwd", "workingDirectory", "workspacePath", "workspace", "projectPath", "directory"]
    }

    /// Candidate keys, tried in order, for a registered-agent record's session id.
    public func registeredJSONLSessionIDKeys() -> [String] {
        ["sessionId", "session_id", "id"]
    }

    /// Candidate keys, tried in order, for an Antigravity record's session id.
    public func antigravitySessionIDKeys() -> [String] {
        ["conversationId", "conversation_id", "sessionId", "session_id", "id"]
    }

    /// The display title for an Antigravity history record, preferring the
    /// `title`/`prompt`/`display` text values and falling back to a top-level
    /// title, or `nil` when none is present.
    ///
    /// - Parameter object: The deserialized history record.
    public func antigravityHistoryTitle(in object: [String: Any]) -> String? {
        fieldParser.firstText(in: object, keys: ["title", "prompt", "display"])
            ?? fieldParser.firstTopLevelTitle(in: object)
    }

    /// Whether an Antigravity history record matches a search needle.
    ///
    /// An empty needle matches everything; otherwise the needle is matched
    /// case-insensitively against the record's session id, title, and cwd.
    ///
    /// - Parameters:
    ///   - needle: The search text.
    ///   - sessionId: The record's session id.
    ///   - title: The record's title.
    ///   - cwd: The record's working directory, if known.
    public func antigravityHistoryMatchesNeedle(
        needle: String,
        sessionId: String,
        title: String,
        cwd: String?
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        return [sessionId, title, cwd ?? ""].contains { value in
            value.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }
    }

    /// The modified date for an Antigravity history record.
    ///
    /// Reads the record's `timestamp`, treating values above ten billion as
    /// milliseconds (otherwise seconds) since the Unix epoch, and falls back when
    /// the timestamp is missing or non-positive.
    ///
    /// - Parameters:
    ///   - object: The deserialized history record.
    ///   - fallback: The date to use when no usable timestamp is present.
    public func antigravityHistoryModifiedDate(
        in object: [String: Any],
        fallback: Date
    ) -> Date {
        guard let timestamp = antigravityNumericTimestamp(object["timestamp"]) else {
            return fallback
        }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Coerces a loosely-typed timestamp value (`NSNumber` or numeric `String`)
    /// to a `Double`, or `nil` when it is neither.
    ///
    /// - Parameter value: The raw `timestamp` value from a history record.
    public func antigravityNumericTimestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Whether a file's UTF-8 contents contain a needle, scanned case-insensitively.
    ///
    /// Streams the file in 64 KiB chunks with a bounded carry-over between chunks
    /// so a needle straddling a chunk boundary is still found, and honors task
    /// cancellation. An empty needle returns `false`.
    ///
    /// - Parameters:
    ///   - url: The file to scan.
    ///   - needle: The substring to search for.
    public func fileContains(_ url: URL, needle: String) -> Bool {
        guard !needle.isEmpty,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let overlapLimit = max(needle.utf8.count * 4, 4 * 1024)
        var carry = Data()
        while !Task.isCancelled {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }

            var buffer = carry
            buffer.append(chunk)
            let text = String(decoding: buffer, as: UTF8.self)
            if text.range(of: needle, options: [.caseInsensitive, .literal]) != nil {
                return true
            }
            carry = buffer.count > overlapLimit ? Data(buffer.suffix(overlapLimit)) : buffer
        }
        return false
    }

    /// Infers the working directory for a Pi session from its parent directory's
    /// `--encoded--path--` name, or `nil` when the name is not in that form or the
    /// decoded path is not an existing directory.
    ///
    /// - Parameter url: The session file URL whose parent directory encodes the path.
    public func piCWDInferred(from url: URL) -> String? {
        let directoryName = url.deletingLastPathComponent().lastPathComponent
        guard directoryName.hasPrefix("--"), directoryName.hasSuffix("--"), directoryName.count > 4 else {
            return nil
        }
        let body = String(directoryName.dropFirst(2).dropLast(2))
        guard !body.isEmpty else { return nil }
        let candidate = "/" + body.replacingOccurrences(of: "-", with: "/")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return candidate
    }
}
