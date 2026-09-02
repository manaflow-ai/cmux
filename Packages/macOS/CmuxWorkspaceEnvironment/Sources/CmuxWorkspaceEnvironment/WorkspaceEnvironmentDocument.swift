import Foundation

/// Stores workspace environment entries and renders their reversible editor text.
///
/// The document keeps the dictionary supplied by its caller. Call ``sanitized(_:)``
/// at an input boundary when the values came from an untrusted workspace
/// creation or restoration path. Serialization escapes backslashes, line breaks,
/// and a leading # in a key, so every value accepted by the sanitizer has an
/// unambiguous line representation.
public struct WorkspaceEnvironmentDocument: Equatable, Sendable {
    /// The environment entries represented by this document.
    public let environment: [String: String]

    /// Creates a document for an environment dictionary.
    ///
    /// - Parameter environment: Entries to render. Call ``sanitized(_:)`` first
    ///   when the entries came from an external input boundary.
    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// A deterministic KEY=VALUE representation suitable for the editor.
    ///
    /// Keys are sorted for stable autosave fingerprints. Structural characters
    /// are escaped with backslash sequences understood by
    /// ``WorkspaceEnvironmentParser``.
    public var serialized: String {
        environment.keys.sorted().compactMap { key in
            guard let value = environment[key] else { return nil }
            return "\(Self.escape(key, isKey: true))=\(Self.escape(value, isKey: false))"
        }.joined(separator: "\n")
    }

    /// Applies the workspace environment input policy.
    ///
    /// Blank keys, NUL-containing keys or values, and keys containing = are
    /// dropped. Keys are trimmed at their boundaries; embedded newlines and
    /// values containing CR/LF remain valid because the document serializer
    /// encodes them reversibly. When multiple accepted input keys normalize to
    /// the same key, all of those colliding entries are rejected so the result
    /// never depends on dictionary iteration order. Empty values are retained;
    /// `NAME=` is a valid environment assignment.
    ///
    /// - Parameter environment: Raw entries from a creation, restore, or UI path.
    /// - Returns: Entries safe to pass to terminal startup and persistence.
    public static func sanitized(_ environment: [String: String]) -> [String: String] {
        var counts: [String: Int] = [:]
        var candidates: [String: String] = [:]

        for pair in environment {
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !key.contains("\0"),
                  !key.contains("="),
                  !pair.value.contains("\0") else {
                continue
            }

            counts[key, default: 0] += 1
            candidates[key] = pair.value
        }

        return candidates.reduce(into: [String: String]()) { result, pair in
            guard counts[pair.key] == 1 else { return }
            result[pair.key] = pair.value
        }
    }

    private static func escape(_ value: String, isKey: Bool) -> String {
        var escaped = String()
        escaped.reserveCapacity(value.utf8.count)
        var isFirstScalar = true

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped.append("\\\\")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "#" where isKey && isFirstScalar:
                escaped.append("\\#")
            default:
                escaped.unicodeScalars.append(scalar)
            }
            isFirstScalar = false
        }

        return escaped
    }
}
