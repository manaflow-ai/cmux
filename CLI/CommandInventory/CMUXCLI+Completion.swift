import ArgumentParser
import Foundation

extension CMUXCLI {
    struct CompletionRoot: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cmux",
            abstract: "Control cmux from the command line."
        )

        @Option(name: .long, parsing: .unconditional, help: "Override the Unix socket path.", completion: .file())
        var socket: String?

        @Flag(name: .long, help: "Print machine-readable JSON where supported.")
        var json = false

        @Option(
            name: .customLong("id-format"),
            parsing: .unconditional,
            help: "Select refs, uuids, or both in supported output.",
            completion: .list(["refs", "uuids", "both"])
        )
        var idFormat: String?

        @Option(name: .long, parsing: .unconditional, help: "Route commands through a specific window where supported.")
        var window: String?

        @Option(name: .long, parsing: .unconditional, help: "Socket auth password.")
        var password: String?

        @Flag(name: [.customShort("v"), .long], help: "Print version information.")
        var version = false

        @Flag(name: [.customShort("h"), .long], help: "Print help information.")
        var help = false

        @Argument(
            parsing: .allUnrecognized,
            help: "Command and command-specific arguments.",
            completion: .custom(Self.commandPathCompletion)
        )
        var command: [String] = []

        mutating func run() throws {}

        private static let commandPathCompletion: @Sendable ([String], Int, String) -> [String] = {
            arguments,
            completingArgumentIndex,
            completingPrefix in
            completeCommandPath(
                arguments: arguments,
                completingArgumentIndex: completingArgumentIndex,
                completingPrefix: completingPrefix
            )
        }

        private static func completeCommandPath(
            arguments: [String],
            completingArgumentIndex: Int,
            completingPrefix: String
        ) -> [String] {
            CMUXCLI.completeCommandPath(
                arguments: arguments,
                completingArgumentIndex: completingArgumentIndex,
                completingPrefix: completingPrefix
            )
        }
    }

    static func isArgumentParserCompletionRequest(_ rawArguments: [String]) -> Bool {
        guard rawArguments.count > 1 else {
            return false
        }
        let first = rawArguments[1]
        return first == "---completion"
            || first == "--generate-completion-script"
            || first.hasPrefix("--generate-completion-script=")
    }

    static func runArgumentParserCompletion(_ rawArguments: [String]) -> Never {
        CompletionRoot.main(Array(rawArguments.dropFirst()))
        exit(EXIT_SUCCESS)
    }

    static func completeCommandPath(
        arguments: [String],
        completingArgumentIndex: Int,
        completingPrefix: String
    ) -> [String] {
        let effectiveCompletingPrefix = commandPathCompletingPrefix(
            arguments: arguments,
            completingArgumentIndex: completingArgumentIndex,
            fallbackPrefix: completingPrefix
        )
        let relevantArguments = completionArguments(
            arguments: arguments,
            completingArgumentIndex: completingArgumentIndex,
            completingPrefix: effectiveCompletingPrefix
        )
        let completedTokens = completedCommandTokens(
            arguments: relevantArguments,
            completingPrefix: effectiveCompletingPrefix
        )
        let candidateIndex = completedTokens.count
        let candidates = argumentParserInventoryTokenPaths.compactMap { path -> String? in
            guard candidateIndex < path.count else {
                return nil
            }
            guard path.prefix(candidateIndex).elementsEqual(completedTokens) else {
                return nil
            }
            let candidate = path[candidateIndex]
            guard effectiveCompletingPrefix.isEmpty || candidate.hasPrefix(effectiveCompletingPrefix) else {
                return nil
            }
            return candidate
        }

        return Array(Set(candidates)).sorted()
    }

    private static func commandPathCompletingPrefix(
        arguments: [String],
        completingArgumentIndex: Int,
        fallbackPrefix: String
    ) -> String {
        guard completingArgumentIndex >= 0,
              completingArgumentIndex < arguments.count else {
            return fallbackPrefix
        }
        return String(arguments[completingArgumentIndex].prefix(fallbackPrefix.count))
    }

    private static func completionArguments(
        arguments: [String],
        completingArgumentIndex: Int,
        completingPrefix: String
    ) -> [String] {
        guard completingArgumentIndex >= 0,
              completingArgumentIndex < arguments.count else {
            return arguments
        }

        if completingPrefix.isEmpty {
            if completingArgumentIndex + 1 < arguments.count {
                return Array(arguments.prefix(completingArgumentIndex))
            }
            return arguments
        }

        return Array(arguments.prefix(completingArgumentIndex))
    }

    private static var argumentParserInventoryTokenPaths: [[String]] {
        argumentParserInventoryForms.map { $0.split(separator: " ").map(String.init) }
    }

    private static func completedCommandTokens(
        arguments: [String],
        completingPrefix: String
    ) -> [String] {
        var tokens = arguments
        if let first = tokens.first, isLikelyExecutableName(first) {
            tokens.removeFirst()
        }
        tokens = stripRootOptions(from: tokens)
        if !completingPrefix.isEmpty, tokens.last == completingPrefix {
            tokens.removeLast()
        }
        return tokens
    }

    private static func stripRootOptions(from tokens: [String]) -> [String] {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if rootFlagTokens.contains(token) {
                index += 1
                continue
            }
            if rootOptionTokens.contains(token) {
                index += 2
                continue
            }
            if rootOptionTokens.contains(where: { token.hasPrefix("\($0)=") }) {
                index += 1
                continue
            }
            break
        }
        return Array(tokens.dropFirst(index))
    }

    private static let rootFlagTokens: Set<String> = [
        "--json",
        "-v",
        "--version",
        "-h",
        "--help"
    ]

    private static let rootOptionTokens: Set<String> = [
        "--socket",
        "--id-format",
        "--window",
        "--password"
    ]

    private static func isLikelyExecutableName(_ token: String) -> Bool {
        let name = URL(fileURLWithPath: token).lastPathComponent
        return name == "cmux" || name.hasPrefix("cmux-dev")
    }
}
