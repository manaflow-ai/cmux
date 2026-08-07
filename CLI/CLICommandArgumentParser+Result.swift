import Foundation

extension CLICommandArgumentParser {
    /// Holds parsed option values and positionals for one command invocation.
    struct Result {
        private let context: String
        private let optionValues: [String: [String]]
        private let flags: Set<String>

        let positionalsBeforeTerminator: [String]
        let argumentsAfterTerminator: [String]?

        init(
            context: String,
            optionValues: [String: [String]],
            flags: Set<String>,
            positionalsBeforeTerminator: [String],
            argumentsAfterTerminator: [String]?
        ) {
            self.context = context
            self.optionValues = optionValues
            self.flags = flags
            self.positionalsBeforeTerminator = positionalsBeforeTerminator
            self.argumentsAfterTerminator = argumentsAfterTerminator
        }

        var positionals: [String] {
            positionalsBeforeTerminator + (argumentsAfterTerminator ?? [])
        }

        func value(for option: String) -> String? {
            optionValues[option]?.last
        }

        func values(for option: String) -> [String] {
            optionValues[option] ?? []
        }

        func contains(_ option: String) -> Bool {
            flags.contains(option)
        }

        func rejectUnexpectedPositionals(allowing allowedCount: Int = 0) throws {
            if let unexpected = positionals.dropFirst(allowedCount).first {
                let format = String(
                    localized: "cli.arguments.error.unexpectedArgument",
                    defaultValue: "%@: unexpected argument '%@'."
                )
                throw CLIError(message: String.localizedStringWithFormat(
                    format,
                    context,
                    unexpected
                ))
            }
        }
    }
}
