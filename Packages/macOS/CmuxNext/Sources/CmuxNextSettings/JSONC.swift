import Foundation

/// JSON with comments, the cmux.json authoring format: `//` and `/* */`
/// comments and trailing commas are allowed. Rust reads it (cmux-tui `cmux-config` `jsonc`, the
/// `jsonc.*` ops of ``SettingsRust``). The app never edits the text: the daemon's settings owner
/// writes the file in place so comments, key order and formatting survive (``SettingsFileWriter``).
public struct JSONC {
    public init() {}
    /// A text that does not read, as a person reads it: where in the file and what, such as
    /// "the text is not valid JSON at line 5, column 3".
    public struct Failure: Error, Sendable, Equatable {
        public let problem: String
    }

    /// Strict JSON text for `source`: comments removed, trailing commas
    /// dropped. String contents are untouched.
    public static func strip(_ source: String) throws -> String {
        let reply = try SettingsRust().call("jsonc.strip", .object(["source": .string(source)]))
        guard let text = reply["text"]?.stringValue else { throw failure(reply) }
        return text
    }

    /// Parses JSONC text. An empty or comment-only document is an empty object.
    public static func parse(_ source: String) throws -> JSONValue {
        let reply = try SettingsRust().call("jsonc.parse", .object(["source": .string(source)]))
        guard let value = reply["value"] else { throw failure(reply) }
        return value
    }

    /// A file's read or parse failure as a person reads it: where in the file and what. Never the
    /// error's dump: the toast and the Settings row showed "Error Domain=NSCocoaErrorDomain
    /// Code=3840 … UserInfo={…}" (Leo, 2026-11-20: "bad toast of unreadable json").
    public static func problem(_ error: any Error, in source: String?) -> String {
        if let failure = error as? Failure { return failure.problem }
        var out = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") { out.removeLast() }
        guard let first = out.first, first.isUppercase, !(out.dropFirst().first?.isUppercase ?? false) else { return out }
        return first.lowercased() + out.dropFirst()
    }

    /// Where the member at `path` starts in `source` (its key's opening quote), as a 1-based line
    /// and column (UTF-16 code units, as the code editor counts); nil when the source does not
    /// parse or has no such member.
    public static func position(of path: [String], in source: String) -> (line: Int, column: Int)? {
        let reply = SettingsRust().answer("jsonc.position", .object(["source": .string(source), "path": .array(path.map { .string($0) })]))
        guard let line = reply["line"]?.intValue, let column = reply["column"]?.intValue else { return nil }
        return (line, column)
    }

    private static func failure(_ reply: JSONValue) -> Failure {
        Failure(problem: reply["problem"]?.stringValue ?? "the text is not valid JSON")
    }
}
