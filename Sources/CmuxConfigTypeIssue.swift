import Foundation

/// A type-level configuration problem tied to a JSON path.
struct CmuxConfigTypeIssue: Equatable, Hashable, Sendable {
    let path: String
    let message: String

    var description: String {
        "\(path): \(message)"
    }

    /// Converts a Codable failure into a concise diagnostic suitable for the
    /// config store, Vault logs, and the no-socket config doctor.
    static func decodingMessage(for error: Error) -> String {
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
}
