/// Parses browser subcommand arguments without depending on AppKit or the CLI executable.
///
/// The parser deliberately keeps user-provided option values out of errors so callers can
/// render diagnostics without disclosing secrets passed on the command line.
public struct BrowserCommandArgumentParser: Sendable {
    /// The positionals and boolean flags accepted by a browser subcommand.
    public struct Result: Equatable, Sendable {
        /// Positional arguments in their original order.
        public let positionals: [String]

        /// Recognized boolean flags.
        public let flags: Set<String>

        /// Creates a parsed browser argument result.
        public init(positionals: [String], flags: Set<String>) {
            self.positionals = positionals
            self.flags = flags
        }
    }

    /// A privacy-safe browser argument validation failure.
    public enum ParseError: Error, Equatable, Sendable {
        /// An unsupported option. Values after an equals sign are always removed.
        case unknownOption(name: String)

        /// A documented option was not followed by a value.
        case missingValue(option: String)

        /// A command received more positional arguments than it accepts.
        case unexpectedPositionals
    }

    private let valueOptions: Set<String>
    private let allowedFlags: Set<String>

    /// Creates a parser for the documented options and flags of one browser subcommand.
    public init(
        valueOptions: Set<String> = [],
        allowedFlags: Set<String> = []
    ) {
        self.valueOptions = valueOptions
        self.allowedFlags = allowedFlags
    }

    /// Parses arguments, honoring `--` and both `--option value` and `--option=value`.
    public func parse(_ values: [String]) throws -> Result {
        var positionals: [String] = []
        var flags: Set<String> = []
        var index = 0
        var pastTerminator = false

        while index < values.count {
            let value = values[index]

            if pastTerminator {
                positionals.append(value)
                index += 1
                continue
            }

            if value == "--" {
                pastTerminator = true
                index += 1
                continue
            }

            if allowedFlags.contains(value) {
                flags.insert(value)
                index += 1
                continue
            }

            if let equal = value.firstIndex(of: "=") {
                let option = String(value[..<equal])
                if valueOptions.contains(option) {
                    let optionValue = value[value.index(after: equal)...]
                    guard !optionValue.isEmpty else {
                        throw ParseError.missingValue(option: option)
                    }
                    index += 1
                    continue
                }
            }

            if valueOptions.contains(value) {
                guard index + 1 < values.count, !values[index + 1].hasPrefix("-") else {
                    throw ParseError.missingValue(option: value)
                }
                index += 2
                continue
            }

            if value.hasPrefix("-") {
                let redactedName = value.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                ).first.map(String.init) ?? "-"
                throw ParseError.unknownOption(name: redactedName)
            }

            positionals.append(value)
            index += 1
        }

        return Result(positionals: positionals, flags: flags)
    }

    /// Ensures a caller did not leave unconsumed positional arguments.
    public static func requireNoExtraPositionals(_ count: Int) throws {
        guard count == 0 else {
            throw ParseError.unexpectedPositionals
        }
    }
}
