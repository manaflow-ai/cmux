import Foundation

/// A type-level configuration problem tied to a JSON path.
struct CmuxConfigTypeIssue: Equatable, Hashable, Sendable {
    let path: String
    let message: String

    init(path: String, message: String) {
        self.path = Self.sanitizeText(path, replacingNewlines: true)
        self.message = Self.sanitizeText(message, replacingNewlines: true)
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
        var seen = Set(primary)
        let coveredEntries = Set(primary.compactMap(\.commandEntryPath))
        for issue in additional where seen.insert(issue).inserted {
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
        sanitizeText(rawDecodingMessage(for: error), replacingNewlines: true)
    }

    private static func rawDecodingMessage(for error: Error) -> String {
        if let splitError = error as? CmuxSplitDecodingError {
            switch splitError {
            case .invalidChildCount(let count):
                let format = String(
                    localized: "config.validation.splitChildCount",
                    defaultValue: "Split layout must contain exactly 2 children (found %@)"
                )
                return String(format: format, arguments: [String(count) as NSString])
            }
        }
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

    /// Removes dangerous invisible controls from configuration diagnostics.
    /// Newlines are replaced only when a message is being rendered inline;
    /// callers that preserve multiline text can leave them unchanged.
    static func sanitizeText(_ value: String, replacingNewlines: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            case 0x0A, 0x0D:
                if replacingNewlines {
                    result.unicodeScalars.append(UnicodeScalar(0x20)!)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
