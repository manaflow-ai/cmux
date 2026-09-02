import Foundation

/// Parses and serializes the line-oriented workspace environment editor format.
///
/// Empty lines and unescaped comment lines are ignored. The first = on an
/// entry separates its key from its value; escaped line breaks and backslashes
/// are decoded after that split. Empty values are preserved, so `NAME=` is a
/// valid assignment.
public struct WorkspaceEnvironmentParser: Sendable {
    /// Errors reported for one malformed editor line.
    public enum ParseError: Error, Equatable, Sendable {
        /// The line did not contain a key/value separator.
        case invalidAssignment(line: Int)
        /// The decoded key was empty.
        case emptyKey(line: Int)
        /// The decoded value was empty under the legacy parser policy.
        ///
        /// The current parser preserves empty values and does not emit this case.
        /// It remains for source compatibility with the original app-local parser.
        case emptyValue(line: Int)
        /// The decoded key contained a NUL or = character.
        case invalidKey(line: Int)
        /// The decoded value contained a NUL character.
        case invalidValue(line: Int)
        /// A decoded key appeared more than once.
        case duplicateKey(line: Int)

        /// The one-based source line associated with this error.
        public var line: Int {
            switch self {
            case let .invalidAssignment(line),
                 let .emptyKey(line),
                 let .emptyValue(line),
                 let .invalidKey(line),
                 let .invalidValue(line),
                 let .duplicateKey(line):
                return line
            }
        }
    }

    /// Creates a stateless workspace environment parser.
    public init() {}

    /// Parses editor text into a workspace environment dictionary.
    ///
    /// - Parameter text: KEY=VALUE entries separated by LF, CRLF, or CR line
    ///   endings. Backslash escapes produced by
    ///   ``WorkspaceEnvironmentDocument.serialized`` are decoded.
    /// - Returns: The parsed entries.
    /// - Throws: ``WorkspaceEnvironmentParser.ParseError`` when a non-comment entry is malformed.
    public func parse(_ text: String) throws -> [String: String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var environment: [String: String] = [:]

        for (offset, rawLine) in normalized.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" }
        ).enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else {
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                throw ParseError.invalidAssignment(line: lineNumber)
            }

            let rawKey = String(line[..<separator])
            let rawValue = String(line[line.index(after: separator)...])
            let key = Self.unescape(rawKey)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = Self.unescape(rawValue)

            guard !key.isEmpty else {
                throw ParseError.emptyKey(line: lineNumber)
            }
            guard !key.contains("\0"), !key.contains("=") else {
                throw ParseError.invalidKey(line: lineNumber)
            }
            guard !value.contains("\0") else {
                throw ParseError.invalidValue(line: lineNumber)
            }
            guard environment.updateValue(value, forKey: key) == nil else {
                throw ParseError.duplicateKey(line: lineNumber)
            }
        }

        return environment
    }

    /// Convenience form of parse(_:) for callers without parser state.
    ///
    /// - Parameter text: Editor text to parse.
    /// - Returns: The parsed entries.
    /// - Throws: ``WorkspaceEnvironmentParser.ParseError`` when an entry is malformed.
    public static func parse(_ text: String) throws -> [String: String] {
        try Self().parse(text)
    }

    /// Serializes an environment using the reversible editor format.
    ///
    /// - Parameter environment: Entries to render, normally after
    ///   ``WorkspaceEnvironmentDocument.sanitized(_:)``.
    /// - Returns: Deterministically ordered KEY=VALUE editor text.
    public func serialize(_ environment: [String: String]) -> String {
        WorkspaceEnvironmentDocument(environment: environment).serialized
    }

    /// Convenience form of serialize(_:) for callers without parser state.
    ///
    /// - Parameter environment: Entries to render.
    /// - Returns: Deterministically ordered KEY=VALUE editor text.
    public static func serialize(_ environment: [String: String]) -> String {
        Self().serialize(environment)
    }

    private static func unescape(_ value: String) -> String {
        var unescaped = String()
        unescaped.reserveCapacity(value.utf8.count)
        var isEscaped = false

        for scalar in value.unicodeScalars {
            if isEscaped {
                switch scalar {
                case "n":
                    unescaped.append("\n")
                case "r":
                    unescaped.append("\r")
                case "\\":
                    unescaped.append("\\")
                case "#":
                    unescaped.append("#")
                default:
                    unescaped.append("\\")
                    unescaped.unicodeScalars.append(scalar)
                }
                isEscaped = false
            } else if scalar == "\\" {
                isEscaped = true
            } else {
                unescaped.unicodeScalars.append(scalar)
            }
        }

        if isEscaped {
            unescaped.append("\\")
        }
        return unescaped
    }
}
