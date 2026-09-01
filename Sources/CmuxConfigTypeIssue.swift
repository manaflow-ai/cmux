import Foundation

/// A type-level configuration problem tied to a JSON path.
struct CmuxConfigTypeIssue: Equatable, Hashable, Sendable {
    let path: String
    let message: String

    init(path: String, message: String) {
        self.path = Self.sanitize(path)
        self.message = Self.sanitize(message)
    }

    var description: String {
        "\(path): \(message)"
    }

    /// Merges validator findings without reporting a decoder failure twice for
    /// the same commands[] entry. A decoder issue at `commands[n]` covers any
    /// more-specific validator path below that entry.
    static func merged(
        _ primary: [CmuxConfigTypeIssue],
        with additional: [CmuxConfigTypeIssue]
    ) -> [CmuxConfigTypeIssue] {
        var result = primary
        let coveredEntries = Set(primary.compactMap(\.commandEntryPath))
        for issue in additional where !result.contains(issue) {
            if let entryPath = issue.commandEntryPath, coveredEntries.contains(entryPath) {
                continue
            }
            result.append(issue)
        }
        return result
    }

    private var commandEntryPath: String? {
        guard path.hasPrefix("commands["),
              let closingBracket = path.firstIndex(of: "]") else {
            return nil
        }
        return String(path[...closingBracket])
    }

    /// Converts a Codable failure into a concise diagnostic suitable for the
    /// config store, Vault logs, and the no-socket config doctor.
    static func decodingMessage(for error: Error) -> String {
        sanitize(rawDecodingMessage(for: error))
    }

    private static func rawDecodingMessage(for error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return contextMessage(context)
        case DecodingError.valueNotFound(_, let context):
            return contextMessage(context)
        case DecodingError.keyNotFound(let key, let context):
            let detail = contextMessage(context)
            guard detail.isEmpty else { return detail }
            let format = String(
                localized: "config.validation.missingKey",
                defaultValue: "Missing required key '%@'"
            )
            return String(format: format, key.stringValue)
        case DecodingError.dataCorrupted(let context):
            return contextMessage(context)
        default:
            let description = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty
                ? String(
                    localized: "config.validation.unknownEntry",
                    defaultValue: "Unknown configuration entry error"
                )
                : description
        }
    }

    private static func contextMessage(_ context: DecodingError.Context) -> String {
        context.debugDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitize(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            case 0x0A, 0x0D:
                result.unicodeScalars.append(UnicodeScalar(0x20)!)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
