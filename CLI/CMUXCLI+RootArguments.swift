import ArgumentParser
import Foundation

extension CMUXCLI {
    func parseCLIArguments<Arguments: ParsableArguments>(
        _ type: Arguments.Type,
        _ args: [String]
    ) throws -> Arguments {
        do {
            return try Arguments.parse(args)
        } catch {
            throw CLIError(message: String(describing: error))
        }
    }

    struct CompatibleCommandArguments: ParsableArguments {
        @Argument(parsing: .allUnrecognized)
        var tokens: [String] = []

        init() {}

        init(tokens: [String] = []) {
            self.tokens = tokens
        }

        func option(_ name: String) -> (String?, [String]) {
            var remaining: [String] = []
            var value: String?
            var skipNext = false
            var pastTerminator = false

            for (idx, arg) in tokens.enumerated() {
                if skipNext {
                    skipNext = false
                    continue
                }
                if arg == "--" {
                    pastTerminator = true
                    remaining.append(arg)
                    continue
                }
                if !pastTerminator, arg == name, idx + 1 < tokens.count {
                    value = tokens[idx + 1]
                    skipNext = true
                    continue
                }
                remaining.append(arg)
            }

            return (value, remaining)
        }

        func repeatedOption(_ name: String) -> ([String], [String]) {
            var remaining: [String] = []
            var values: [String] = []
            var skipNext = false
            var pastTerminator = false

            for (idx, arg) in tokens.enumerated() {
                if skipNext {
                    skipNext = false
                    continue
                }
                if arg == "--" {
                    pastTerminator = true
                    remaining.append(arg)
                    continue
                }
                if !pastTerminator, arg == name, idx + 1 < tokens.count {
                    values.append(tokens[idx + 1])
                    skipNext = true
                    continue
                }
                remaining.append(arg)
            }

            return (values, remaining)
        }

        func value(for name: String) -> String? {
            guard let index = tokens.firstIndex(of: name), index + 1 < tokens.count else {
                return nil
            }
            return tokens[index + 1]
        }

        func hasFlag(_ name: String) -> Bool {
            tokens.contains(name)
        }
    }

    func parseCompatibleCommandArguments(_ args: [String]) -> CompatibleCommandArguments {
        (try? parseCLIArguments(CompatibleCommandArguments.self, args)) ?? CompatibleCommandArguments(tokens: args)
    }

    struct RootArguments: ParsableArguments {
        @Option(name: .long, parsing: .unconditional, help: "Override the Unix socket path.")
        var socket: String?

        @Flag(name: .long, help: "Print machine-readable JSON where supported.")
        var json = false

        @Option(name: .customLong("id-format"), parsing: .unconditional, help: "Select refs, uuids, or both in supported output.")
        var idFormat: String?

        @Option(name: .long, parsing: .unconditional, help: "Route commands through a specific window where supported.")
        var window: String?

        @Option(name: .long, parsing: .unconditional, help: "Socket auth password.")
        var password: String?

        @Flag(name: [.customShort("v"), .long], help: "Print version information.")
        var version = false

        @Flag(name: [.customShort("h"), .long], help: "Print help information.")
        var help = false
    }

    struct RootParseResult {
        let arguments: RootArguments
        let commandIndex: Int
    }

    func parseRootArguments() throws -> RootParseResult {
        let split = try rootArgumentPrefix()
        do {
            let arguments = try RootArguments.parse(normalizedRootArgumentPrefix(split.prefix))
            return RootParseResult(arguments: arguments, commandIndex: split.commandIndex)
        } catch {
            throw CLIError(message: String(describing: error))
        }
    }

    private func rootArgumentPrefix() throws -> (prefix: [String], commandIndex: Int) {
        var prefix: [String] = []
        var index = 1

        while index < args.count {
            let arg = args[index]

            if let attached = attachedRootOption(arg) {
                prefix.append(attached.option)
                prefix.append(attached.value)
                index += 1
                continue
            }

            switch arg {
            case "--socket":
                try appendRootOption(arg, to: &prefix, index: &index, missingValueMessage: "--socket requires a path")
            case "--id-format":
                try appendRootOption(arg, to: &prefix, index: &index, missingValueMessage: "--id-format requires a value (refs|uuids|both)")
            case "--window":
                try appendRootOption(arg, to: &prefix, index: &index, missingValueMessage: "--window requires a window id")
            case "--password":
                try appendRootOption(arg, to: &prefix, index: &index, missingValueMessage: "--password requires a value")
            case "--json":
                prefix.append(arg)
                index += 1
            case "-v", "--version", "-h", "--help":
                prefix.append(arg)
                return (prefix, index + 1)
            default:
                return (prefix, index)
            }
        }

        return (prefix, index)
    }

    private func attachedRootOption(_ arg: String) -> (option: String, value: String)? {
        for option in rootArgumentOptionTokens where arg.hasPrefix("\(option)=") {
            return (option, String(arg.dropFirst(option.count + 1)))
        }
        return nil
    }

    private func normalizedRootArgumentPrefix(_ prefix: [String]) -> [String] {
        var optionValues: [String: String] = [:]
        var optionOrder: [String] = []
        var flags: Set<String> = []
        var flagOrder: [String] = []
        var index = 0

        while index < prefix.count {
            let token = prefix[index]
            if rootArgumentOptionTokens.contains(token), index + 1 < prefix.count {
                if optionValues[token] == nil {
                    optionOrder.append(token)
                }
                optionValues[token] = prefix[index + 1]
                index += 2
                continue
            }

            if rootArgumentFlagTokens.contains(token) {
                if flags.insert(token).inserted {
                    flagOrder.append(token)
                }
                index += 1
                continue
            }

            index += 1
        }

        var normalized: [String] = []
        for option in optionOrder {
            guard let value = optionValues[option] else {
                continue
            }
            normalized.append(option)
            normalized.append(value)
        }
        normalized.append(contentsOf: flagOrder)
        return normalized
    }

    private func appendRootOption(
        _ option: String,
        to prefix: inout [String],
        index: inout Int,
        missingValueMessage: String
    ) throws {
        guard index + 1 < args.count else {
            throw CLIError(message: missingValueMessage)
        }
        prefix.append(option)
        prefix.append(args[index + 1])
        index += 2
    }

    private var rootArgumentFlagTokens: Set<String> {
        [
            "--json",
            "-v",
            "--version",
            "-h",
            "--help"
        ]
    }

    private var rootArgumentOptionTokens: Set<String> {
        [
            "--socket",
            "--id-format",
            "--window",
            "--password"
        ]
    }
}
