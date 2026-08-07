import Foundation

/// Parses one CLI command's options without losing the distinction between
/// positionals, unknown options, and arguments intentionally passed after `--`.
struct CLICommandArgumentParser {
    let context: String
    let options: [Option]
    let optionParsing: OptionParsing

    init(
        context: String,
        options: [Option],
        optionParsing: OptionParsing = .interspersed
    ) {
        self.context = context
        self.options = options
        self.optionParsing = optionParsing
    }

    func parse(_ arguments: [String]) throws -> Result {
        let definitions = Dictionary(uniqueKeysWithValues: options.map { ($0.name, $0) })
        var optionValues: [String: [String]] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return Result(
                    context: context,
                    optionValues: optionValues,
                    flags: flags,
                    positionalsBeforeTerminator: positionals,
                    argumentsAfterTerminator: Array(arguments.dropFirst(index + 1))
                )
            }

            guard isFlag(argument) else {
                if optionParsing == .beforeFirstPositional {
                    let tail = Array(arguments[index...])
                    if let terminatorIndex = tail.firstIndex(of: "--") {
                        positionals.append(contentsOf: tail[..<terminatorIndex])
                        return Result(
                            context: context,
                            optionValues: optionValues,
                            flags: flags,
                            positionalsBeforeTerminator: positionals,
                            argumentsAfterTerminator: Array(tail.dropFirst(terminatorIndex + 1))
                        )
                    }
                    positionals.append(contentsOf: tail)
                    return Result(
                        context: context,
                        optionValues: optionValues,
                        flags: flags,
                        positionalsBeforeTerminator: positionals,
                        argumentsAfterTerminator: nil
                    )
                }
                positionals.append(argument)
                index += 1
                continue
            }

            let attached = attachedValue(in: argument)
            let optionName = attached?.name ?? argument
            guard let definition = definitions[optionName] else {
                throw unknownFlagError(optionName)
            }

            switch definition.kind {
            case .flag:
                guard attached == nil else {
                    throw unexpectedValueError(optionName)
                }
                flags.insert(optionName)
                index += 1

            case .value(_, let repeatable):
                let value: String
                if let attached {
                    value = attached.value
                } else {
                    let valueIndex = index + 1
                    guard valueIndex < arguments.count,
                          arguments[valueIndex] != "--" else {
                        throw missingValueError(optionName)
                    }
                    // Required options own the next token, including values such as `-1` and `-c`.
                    value = arguments[valueIndex]
                    index += 1
                }
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw missingValueError(optionName)
                }
                if repeatable {
                    optionValues[optionName, default: []].append(value)
                } else {
                    optionValues[optionName] = [value]
                }
                index += 1

            case .optionalValue:
                let value: String
                if let attached {
                    value = attached.value
                } else if index + 1 < arguments.count,
                          arguments[index + 1] != "--",
                          !isFlag(arguments[index + 1]) {
                    value = arguments[index + 1]
                    index += 1
                } else {
                    value = ""
                }
                optionValues[optionName] = [value]
                index += 1
            }
        }

        return Result(
            context: context,
            optionValues: optionValues,
            flags: flags,
            positionalsBeforeTerminator: positionals,
            argumentsAfterTerminator: nil
        )
    }

    private func isFlag(_ argument: String) -> Bool {
        argument.hasPrefix("-") && argument != "-"
    }

    private func attachedValue(in argument: String) -> (name: String, value: String)? {
        guard let separator = argument.firstIndex(of: "="), separator != argument.startIndex else {
            return nil
        }
        return (
            String(argument[..<separator]),
            String(argument[argument.index(after: separator)...])
        )
    }

    private var knownFlags: String {
        guard !options.isEmpty else {
            return String(localized: "cli.arguments.knownFlags.none", defaultValue: "(none)")
        }
        let sortedOptions = options.sorted { $0.name < $1.name }
        let format = String(
            localized: "cli.arguments.knownFlags.list",
            defaultValue: "%@. Usage: %@"
        )
        return String.localizedStringWithFormat(
            format,
            sortedOptions.map(\.name).joined(separator: ", "),
            sortedOptions.map(\.usage).joined(separator: ", ")
        )
    }

    private func unknownFlagError(_ flag: String) -> CLIError {
        let format = String(
            localized: "cli.arguments.error.unknownFlag",
            defaultValue: "%@: unknown flag '%@'. Known flags: %@"
        )
        return CLIError(message: String.localizedStringWithFormat(
            format,
            context,
            flag,
            knownFlags
        ))
    }

    private func missingValueError(_ flag: String) -> CLIError {
        let format = String(
            localized: "cli.arguments.error.missingValue",
            defaultValue: "%@: %@ requires a value. Known flags: %@"
        )
        return CLIError(message: String.localizedStringWithFormat(
            format,
            context,
            flag,
            knownFlags
        ))
    }

    private func unexpectedValueError(_ flag: String) -> CLIError {
        let format = String(
            localized: "cli.arguments.error.unexpectedValue",
            defaultValue: "%@: %@ does not take a value. Known flags: %@"
        )
        return CLIError(message: String.localizedStringWithFormat(
            format,
            context,
            flag,
            knownFlags
        ))
    }
}
