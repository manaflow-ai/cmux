public import Foundation

/// A fail-closed parse error for agent-manifest diagnostic arguments.
public enum AgentManifestDiagnosticArgumentError: Error, Equatable, Sendable, LocalizedError {
    /// An option was not followed by a value.
    case missingValue(option: String)
    /// An option or positional surface explicitly supplied an empty value.
    case emptyValue(option: String)
    /// A named option appeared more than once.
    case duplicateOption(option: String)
    /// More than one positional or named surface was supplied.
    case multipleSurfaces
    /// A token is outside the command's closed argument grammar.
    case unexpectedArgument(String)
    /// A quoted v1 argument did not contain its closing quote.
    case unterminatedQuote(Character)
    /// A v1 command ended with an incomplete escape sequence.
    case danglingEscape

    /// Localized, command-specific explanation suitable for a CLI response.
    public var errorDescription: String? {
        let key: StaticString
        let defaultValue: String.LocalizationValue
        let argument: String?
        switch self {
        case .missingValue(let option):
            key = "cli.agentManifests.error.optionValueMissing"
            defaultValue = "debug-agent-manifest requires a value after %@."
            argument = option
        case .emptyValue(let option):
            key = "cli.agentManifests.error.optionValueEmpty"
            defaultValue = "debug-agent-manifest does not accept an empty value for %@."
            argument = option
        case .duplicateOption(let option):
            key = "cli.agentManifests.error.optionDuplicate"
            defaultValue = "debug-agent-manifest accepts %@ only once."
            argument = option
        case .multipleSurfaces:
            key = "cli.agentManifests.error.multipleSurfaces"
            defaultValue = "debug-agent-manifest accepts only one surface."
            argument = nil
        case .unexpectedArgument(let value):
            key = "cli.agentManifests.error.debugUnexpectedArgument"
            defaultValue = "debug-agent-manifest received an unexpected argument '%@'."
            argument = value
        case .unterminatedQuote(let quote):
            key = "cli.agentManifests.error.unterminatedQuote"
            defaultValue = "debug-agent-manifest has an unterminated %@ quote."
            argument = String(quote)
        case .danglingEscape:
            key = "cli.agentManifests.error.danglingEscape"
            defaultValue = "debug-agent-manifest ends with an incomplete escape sequence."
            argument = nil
        }
        let format = String(localized: key, defaultValue: defaultValue)
        return argument.map { String.localizedStringWithFormat(format, $0) } ?? format
    }
}
