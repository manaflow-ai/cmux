import ArgumentParser
import Foundation

extension CMUXCLI {
    struct FeedClearArguments: ParsableArguments {
        @Flag(name: [.long, .customShort("y")], help: "Skip the confirmation prompt.")
        var yes = false

        @Argument(parsing: .allUnrecognized)
        var passthrough: [String] = []

        var skipConfirm: Bool {
            yes || passthrough.contains("--yes") || passthrough.contains("-y")
        }
    }

    struct FeedTUIArguments: ParsableArguments {
        @Flag(name: .long, help: "Force the OpenTUI implementation and fail if unavailable.")
        var opentui = false

        @Flag(name: .long, help: "Force the older built-in Swift TUI.")
        var legacy = false

        @Flag(name: [.long, .customShort("h")], help: "Print help information.")
        var help = false

        @Argument(parsing: .allUnrecognized)
        var passthrough: [String] = []

        func implementation() throws -> FeedTUIImplementation? {
            if help {
                print("Usage: cmux feed tui [--opentui|--legacy]")
                return nil
            }
            if let unknown = passthrough.first {
                throw CLIError(message: "cmux feed tui: unknown argument \(unknown)")
            }
            if opentui && legacy {
                throw CLIError(message: "cmux feed tui: choose only one TUI implementation")
            }
            if opentui { return .openTUI }
            if legacy { return .legacy }
            return .automatic
        }
    }

    func runFeed(commandArgs: [String], socketPath: String, socketPassword: String?) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        _ = parseKnownCommandName(FeedSubcommandName.self, raw: subcommand)

        switch subcommand {
        case "clear":
            let parsed = try parseFeedClearArguments(Array(commandArgs.dropFirst()))
            try runFeedClear(skipConfirm: parsed.skipConfirm)
        case "tui":
            let parsed = try parseFeedTUIArguments(Array(commandArgs.dropFirst()))
            guard let implementation = try parsed.implementation() else { return }
            try runFeedTUI(implementation: implementation, socketPath: socketPath, socketPassword: socketPassword)
        case "help", "--help", "-h":
            print("Usage: cmux feed tui [--opentui|--legacy]\n       cmux feed clear [--yes|-y]")
        default:
            throw CLIError(message: "Unknown feed subcommand: \(subcommand)")
        }
    }

    private func parseFeedClearArguments(_ args: [String]) throws -> FeedClearArguments {
        try parseCLIArguments(FeedClearArguments.self, args)
    }

    private func parseFeedTUIArguments(_ args: [String]) throws -> FeedTUIArguments {
        try parseCLIArguments(FeedTUIArguments.self, args)
    }
}
