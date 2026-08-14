import Foundation

/// Validated arguments for the read-only agent-manifest pane diagnostic.
public struct AgentManifestDiagnosticArguments: Equatable, Sendable {
    /// Optional surface reference. `nil` selects the caller's focused surface.
    public let surface: String?
    /// Optional OSC bytes supplied alongside the captured screen.
    public let osc: String?

    /// Creates validated diagnostic arguments.
    ///
    /// - Parameters:
    ///   - surface: An optional surface reference.
    ///   - osc: Optional captured OSC bytes.
    public init(surface: String? = nil, osc: String? = nil) {
        self.surface = surface
        self.osc = osc
    }

    /// Parses shell-tokenized CLI arguments using the diagnostic's closed option set.
    ///
    /// - Parameter arguments: Tokens following `debug-agent-manifest`.
    /// - Returns: Validated arguments or a precise parse failure.
    public static func parse(
        arguments: [String]
    ) -> Result<AgentManifestDiagnosticArguments, AgentManifestDiagnosticArgumentError> {
        var surface: String?
        var osc: String?
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let token = arguments[index]
            if token == "--surface" || token == "--osc" {
                let option = token
                guard arguments.index(after: index) < arguments.endIndex else {
                    return .failure(.missingValue(option: option))
                }
                let valueIndex = arguments.index(after: index)
                let value = arguments[valueIndex]
                guard !value.hasPrefix("--") else {
                    return .failure(.missingValue(option: option))
                }
                if let failure = assign(
                    option: option,
                    value: value,
                    surface: &surface,
                    osc: &osc
                ) {
                    return .failure(failure)
                }
                index = arguments.index(after: valueIndex)
                continue
            }

            if token.hasPrefix("--surface=") || token.hasPrefix("--osc=") {
                let separator = token.firstIndex(of: "=")!
                let option = String(token[..<separator])
                let value = String(token[token.index(after: separator)...])
                if let failure = assign(
                    option: option,
                    value: value,
                    surface: &surface,
                    osc: &osc
                ) {
                    return .failure(failure)
                }
                index = arguments.index(after: index)
                continue
            }

            if token.hasPrefix("--") {
                return .failure(.unexpectedArgument(token))
            }
            guard !token.isEmpty else {
                return .failure(.emptyValue(option: "--surface"))
            }
            guard surface == nil else {
                return .failure(.multipleSurfaces)
            }
            surface = token
            index = arguments.index(after: index)
        }

        return .success(AgentManifestDiagnosticArguments(surface: surface, osc: osc))
    }

    /// Tokenizes and parses a v1 space-delimited socket command payload.
    ///
    /// - Parameter commandLine: The text following `debug_agent_manifest`.
    /// - Returns: Validated arguments or a precise tokenization/parse failure.
    public static func parse(
        commandLine: String
    ) -> Result<AgentManifestDiagnosticArguments, AgentManifestDiagnosticArgumentError> {
        switch tokenize(commandLine) {
        case let .success(tokens):
            return parse(arguments: tokens)
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func assign(
        option: String,
        value: String,
        surface: inout String?,
        osc: inout String?
    ) -> AgentManifestDiagnosticArgumentError? {
        guard !value.isEmpty else { return .emptyValue(option: option) }
        switch option {
        case "--surface":
            guard surface == nil else { return .duplicateOption(option: option) }
            surface = value
        case "--osc":
            guard osc == nil else { return .duplicateOption(option: option) }
            osc = value
        default:
            return .unexpectedArgument(option)
        }
        return nil
    }

    private static func tokenize(
        _ commandLine: String
    ) -> Result<[String], AgentManifestDiagnosticArgumentError> {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasValue = false

        for character in commandLine {
            if escaping {
                switch character {
                case "n": current.append("\n")
                case "r": current.append("\r")
                case "t": current.append("\t")
                default: current.append(character)
                }
                escaping = false
                hasValue = true
                continue
            }
            if character == "\\" {
                escaping = true
                hasValue = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                    hasValue = true
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasValue = true
                continue
            }
            if character.isWhitespace {
                if hasValue {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                    hasValue = false
                }
                continue
            }
            current.append(character)
            hasValue = true
        }

        if escaping { return .failure(.danglingEscape) }
        if let quote { return .failure(.unterminatedQuote(quote)) }
        if hasValue { tokens.append(current) }
        return .success(tokens)
    }
}
