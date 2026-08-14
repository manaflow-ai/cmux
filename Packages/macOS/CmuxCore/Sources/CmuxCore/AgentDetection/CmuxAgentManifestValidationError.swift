public import Foundation

/// A localized manifest validation failure with an actionable JSON path.
public struct CmuxAgentManifestValidationError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// JSON-style path such as `states[1].screenRegex[0].pattern`.
    public let path: String
    /// Localized reason that the value at ``path`` was rejected.
    public let reason: String

    /// Creates a validation failure.
    ///
    /// - Parameters:
    ///   - path: JSON-style path to the rejected value.
    ///   - reason: Localized explanation of the validation failure.
    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    /// Concise localized diagnostic including ``path`` when available.
    public var description: String {
        guard !path.isEmpty else { return reason }
        return CmuxAgentManifestCodec.localizedReason(
            "agentManifest.error.invalidFile",
            defaultValue: "%1$@: %2$@",
            arguments: [path, reason]
        )
    }

    /// Localized-error bridge for logging and command output.
    public var errorDescription: String? { description }
}
