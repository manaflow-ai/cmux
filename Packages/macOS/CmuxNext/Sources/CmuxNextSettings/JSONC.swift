import Foundation

/// JSON with comments, the cmux.json authoring format: `//` and `/* */`
/// comments and trailing commas are allowed. Reads strip them. The app never
/// edits the text: the daemon's settings owner (cmux-tui `cmux-config`
/// `jsonc`) writes the file in place so comments, key order and formatting
/// survive (``SettingsFileWriter``).
public struct JSONC {
    public init() {}
    public enum Failure: Error, Sendable, Equatable {
        case unterminatedComment
        case unterminatedString
        case malformed(offset: Int)
    }

    // MARK: - Reading

    /// Strict JSON text for `source`: comments removed (their newlines kept), trailing commas
    /// dropped, a leading BOM dropped. String contents are untouched. cmux-config's `jsonc::strip`.
    public static func strip(_ source: String) throws -> String {
        guard let reply = CmuxSettingsFFI.call("jsonc.strip", ["source": source]) else { throw Failure.malformed(offset: 0) }
        if let strict = reply["text"] as? String { return strict }
        switch reply["problem"] as? String {
        case "a /* comment is never closed": throw Failure.unterminatedComment
        case "a string is never closed": throw Failure.unterminatedString
        default: throw Failure.malformed(offset: 0)
        }
    }

    /// Parses JSONC text. An empty or comment-only document is an empty object.
    public static func parse(_ source: String) throws -> JSONValue {
        let strict = try strip(source)
        if strict.allSatisfy(\.isWhitespace) { return .object([:]) }
        return try JSONValue.parse(Data(strict.utf8))
    }
}
