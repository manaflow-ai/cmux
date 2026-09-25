/// Parses presentation flags that may appear before or after a cmux command.
///
/// The parser removes only presentation options. Command options and their
/// values remain in their original order for the command-specific parser.
public struct CmuxCLIArgumentParser: Sendable {
    /// The result of parsing one command's arguments.
    public struct Result: Equatable, Sendable {
        /// Whether the command should render JSON output.
        public let jsonOutput: Bool
        /// The requested identifier format, when supplied.
        public let idFormat: String?
        /// Arguments forwarded to the command-specific parser.
        public let remaining: [String]

        /// Creates a parsed presentation-options result.
        ///
        /// - Parameters:
        ///   - jsonOutput: Whether JSON output was requested.
        ///   - idFormat: The optional identifier format.
        ///   - remaining: Arguments that are not presentation options.
        public init(jsonOutput: Bool, idFormat: String?, remaining: [String]) {
            self.jsonOutput = jsonOutput
            self.idFormat = idFormat
            self.remaining = remaining
        }
    }

    /// Errors produced while parsing presentation options.
    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        /// `--id-format` did not have a following value.
        case missingIDFormatValue

        /// A stable CLI-facing description for this parse failure.
        public var description: String {
            switch self {
            case .missingIDFormatValue:
                "--id-format requires a value (refs|uuids|both)"
            }
        }
    }

    private static let commandOptionsWithValues: Set<String> = [
        "--action", "--after-workspace", "--agent", "--amount", "--arch",
        "--attr", "--before-workspace", "--body", "--color", "--command",
        "--config", "--cwd", "--description", "--direction", "--domain",
        "--dx", "--dy", "--email", "--event", "--expires", "--focus",
        "--function", "--id", "--image", "--index", "--key", "--kind",
        "--label", "--layout", "--lines", "--load-state", "--max-depth", "--name", "--os",
        "--order", "--out", "--pane", "--panel", "--path", "--profile", "--property",
        "--provider", "--relay-port", "--script", "--selector", "--session",
        "--shell", "--source", "--subtitle", "--surface", "--tab", "--target-pane", "--team",
        "--text", "--timeout", "--timeout-ms", "--title", "--transcript",
        "--turn", "--type", "--url", "--url-contains", "--value", "--window",
        "--workspace", "--checkpoint", "--checkpoint-id",
    ]

    /// Creates the parser with cmux's command-option vocabulary.
    public init() {}

    /// Extracts presentation flags while preserving command arguments.
    ///
    /// Presentation flags remain valid after a command and its subcommand.
    /// A `--` terminator stops presentation parsing. Known command options
    /// consume their following value, even when that value begins with `-`.
    ///
    /// - Parameter commandArgs: Arguments after the top-level command.
    /// - Returns: The presentation flags and the command arguments to forward.
    /// - Throws: ``ParseError/missingIDFormatValue`` when `--id-format` has no value.
    public func parse(_ commandArgs: [String]) throws -> Result {
        var jsonOutput = false
        var idFormat: String?
        var remaining: [String] = []
        var index = 0
        var pastTerminator = false
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if pastTerminator {
                remaining.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                index += 1
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < commandArgs.count else {
                    throw ParseError.missingIDFormatValue
                }
                idFormat = commandArgs[index + 1]
                index += 2
                continue
            }
            if !arg.hasPrefix("-") {
                remaining.append(arg)
                index += 1
                continue
            }
            remaining.append(arg)
            if Self.commandOptionsWithValues.contains(arg), index + 1 < commandArgs.count {
                remaining.append(commandArgs[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return Result(jsonOutput: jsonOutput, idFormat: idFormat, remaining: remaining)
    }
}
