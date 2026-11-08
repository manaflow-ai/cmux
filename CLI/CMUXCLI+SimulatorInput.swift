import Foundation

extension CMUXCLI {
    func parseSimulatorArguments(_ args: [String]) throws -> SimulatorArguments {
        var result = SimulatorArguments()
        var index = 0
        var readsPositionalsOnly = false
        while index < args.count {
            let argument = args[index]
            if readsPositionalsOnly { result.positionals.append(argument) }
            else if argument == "--" { readsPositionalsOnly = true }
            else if argument == "--stdin" { result.readsStandardInput = true }
            else if argument == "--surface" || argument == "--file" || argument == "--value" {
                guard index + 1 < args.count else {
                    throw CLIError(message: String.localizedStringWithFormat(
                        String(localized: "cli.simulator.error.missingOptionValue",
                               defaultValue: "simulator: %@ requires a value"), argument
                    ))
                }
                index += 1
                if argument == "--surface" { result.surface = args[index] }
                else if argument == "--file" { result.file = args[index] }
                else { result.optionValue = args[index] }
            } else if argument.hasPrefix("--value=") {
                let value = String(argument.dropFirst("--value=".count))
                guard !value.isEmpty else {
                    throw CLIError(message: String.localizedStringWithFormat(
                        String(localized: "cli.simulator.error.missingOptionValue",
                               defaultValue: "simulator: %@ requires a value"), "--value"
                    ))
                }
                result.optionValue = value
            } else if argument.hasPrefix("--") {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.simulator.error.unknownFlag",
                           defaultValue: "simulator: unknown flag '%@'"), argument
                ))
            } else { result.positionals.append(argument) }
            index += 1
        }
        return result
    }

    func simulatorSourceValue(
        _ arguments: SimulatorArguments,
        maximumBytes: Int
    ) throws -> String {
        guard arguments.optionValue == nil else {
            throw simulatorArgumentsError("input")
        }
        guard arguments.positionals.count <= 1 else {
            throw CLIError(message: String(
                localized: "cli.simulator.error.unexpectedArgument",
                defaultValue: "simulator input accepts one quoted positional value"
            ))
        }
        let sourceCount = (arguments.positionals.isEmpty ? 0 : 1)
            + (arguments.readsStandardInput ? 1 : 0) + (arguments.file == nil ? 0 : 1)
        guard sourceCount > 0 else {
            throw CLIError(message: String(
                localized: "cli.simulator.error.sourceRequired",
                defaultValue: "simulator input requires a positional value, --stdin, or --file"
            ))
        }
        guard sourceCount == 1 else {
            throw CLIError(message: String(
                localized: "cli.simulator.error.sourcesExclusive",
                defaultValue: "simulator input sources are mutually exclusive"
            ))
        }
        if let value = arguments.positionals.first {
            try validateSimulatorInput(value, maximumBytes: maximumBytes)
            return value
        }
        let data: Data
        if arguments.readsStandardInput {
            data = try readBoundedSimulatorInput(
                FileHandle.standardInput, maximumBytes: maximumBytes, closesHandle: false
            )
        } else if let path = arguments.file {
            data = try readBoundedSimulatorInput(
                FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
                maximumBytes: maximumBytes,
                closesHandle: true
            )
        } else { data = Data() }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CLIError(message: String(
                localized: "cli.simulator.error.invalidUTF8",
                defaultValue: "simulator input must be valid UTF-8"
            ))
        }
        return value
    }

    func requireNoSimulatorSource(
        _ arguments: SimulatorArguments,
        subcommand: String
    ) throws {
        guard arguments.positionals.isEmpty,
              !arguments.readsStandardInput,
              arguments.file == nil,
              arguments.optionValue == nil else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.simulator.error.unexpectedArgumentForCommand",
                       defaultValue: "simulator %@ does not accept input"), subcommand
            ))
        }
    }

    func printSimulatorTargets(_ payload: [String: Any]) {
        let targets = payload["targets"] as? [[String: Any]] ?? []
        guard !targets.isEmpty else {
            print(String(localized: "cli.simulator.output.noTargets",
                         defaultValue: "No Web Inspector targets"))
            return
        }
        for target in targets {
            print([
                simulatorTerminalText(target["id"] as? String ?? "?"),
                simulatorTerminalText(target["application_name"] as? String ?? "?"),
                simulatorTerminalText(target["title"] as? String ?? ""),
                simulatorTerminalText(target["url"] as? String ?? ""),
            ].joined(separator: "\t"))
        }
    }

    private func readBoundedSimulatorInput(
        _ handle: FileHandle, maximumBytes: Int, closesHandle: Bool
    ) throws -> Data {
        defer { if closesHandle { try? handle.close() } }
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0,
                  let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw simulatorInputTooLarge(maximumBytes) }
        return data
    }

    private func validateSimulatorInput(_ value: String, maximumBytes: Int) throws {
        guard value.utf8.count <= maximumBytes else { throw simulatorInputTooLarge(maximumBytes) }
    }

    private func simulatorInputTooLarge(_ maximumBytes: Int) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(localized: "cli.simulator.error.inputTooLarge",
                   defaultValue: "simulator input exceeds the %lld-byte UTF-8 limit"), maximumBytes
        ))
    }
}
