import Foundation

/// Errors reported while loading, validating, or updating automation rules.
nonisolated enum AutomationConfigStoreError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case ruleNotFound(String)
    case invalidRule(String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            let format = String(
                localized: "automation.error.unsupportedVersion",
                defaultValue: "Unsupported automation configuration version %lld"
            )
            return String.localizedStringWithFormat(format, Int64(version))
        case .ruleNotFound(let id):
            let format = String(
                localized: "automation.error.ruleNotFound",
                defaultValue: "Automation rule not found: %@"
            )
            return String.localizedStringWithFormat(format, id)
        case .invalidRule(let message):
            let format = String(
                localized: "automation.error.invalidRule",
                defaultValue: "Invalid automation rule: %@"
            )
            return String.localizedStringWithFormat(format, message)
        case .fileTooLarge:
            return String(
                localized: "automation.error.fileTooLarge",
                defaultValue: "Automation configuration is larger than 4 MiB"
            )
        }
    }
}
