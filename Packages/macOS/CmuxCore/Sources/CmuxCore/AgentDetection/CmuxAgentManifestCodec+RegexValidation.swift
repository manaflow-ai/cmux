import Foundation

extension CmuxAgentManifestCodec {
    /// Validates one regular expression for syntax, size, and bounded
    /// backtracking before it can enter an accepted catalog generation.
    static func validateRegex(
        _ regex: CmuxAgentRegexPattern,
        path: String
    ) throws {
        guard !regex.pattern.isEmpty else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.regexBlank",
                    defaultValue: "Regular expression must not be blank"
                )
            )
        }
        guard regex.pattern.utf8.count <= maximumRegexLength else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.regexTooLong",
                    defaultValue: "Regular expression is too long"
                )
            )
        }
        var options: NSRegularExpression.Options = []
        if regex.caseInsensitive { options.insert(.caseInsensitive) }
        if regex.dotMatchesNewlines { options.insert(.dotMatchesLineSeparators) }
        do {
            _ = try NSRegularExpression(pattern: regex.pattern, options: options)
        } catch {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.invalidRegex",
                    defaultValue: "Invalid regular expression: %@",
                    arguments: [error.localizedDescription]
                )
            )
        }
        guard CmuxAgentRegexSafetyValidator.isSafe(regex.pattern) else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.unsafeRegex",
                    defaultValue: "Regular expression uses constructs that cannot be evaluated safely"
                )
            )
        }
    }
}
