import Darwin
import Foundation

extension CMUXCLI {
    /// Hidden compatibility bridge used while cmux grows native Herdr API parity.
    ///
    /// Keep this deliberately small: aliases are translated to Herdr's public CLI,
    /// then `exec` replaces cmux so stdout, stderr, signals, and exit status remain
    /// exactly those of Herdr.
    func runHerdrCompat(commandArgs: [String], jsonOutput: Bool) throws {
        let usage = Self.herdrCompatUsage
        if commandArgs.first.map({ $0 == "--help" || $0 == "-h" }) ?? false {
            print(usage)
            return
        }

        guard let command = commandArgs.first else {
            throw CLIError(message: usage, exitCode: 2)
        }
        guard let translated = Self.herdrCompatArguments(
            command: command,
            arguments: Array(commandArgs.dropFirst()),
            jsonOutput: jsonOutput
        ) else {
            let format = String(
                localized: "cli.herdrCompat.error.unknownCommand",
                defaultValue: "Unknown compatibility command '%1$@'. Supported commands: %2$@."
            )
            throw CLIError(
                message: String(format: format, command, Self.herdrCompatCommandList),
                exitCode: 2
            )
        }
        guard let executable = resolveExecutableInSearchPath(
            "herdr",
            searchPath: ProcessInfo.processInfo.environment["PATH"]
        ) else {
            throw CLIError(
                message: missingProviderExecutableMessage(
                    displayName: "Herdr",
                    executableName: "herdr"
                ),
                exitCode: 127
            )
        }

        var cArguments: [UnsafeMutablePointer<CChar>?] = []
        for argument in [executable] + translated {
            guard let duplicated = strdup(argument) else {
                Self.freeHerdrCompatArguments(cArguments)
                throw herdrCompatLaunchError()
            }
            cArguments.append(duplicated)
        }
        cArguments.append(nil)
        defer { Self.freeHerdrCompatArguments(cArguments) }
        _ = cliExecFailureErrno {
            execv(executable, &cArguments)
        }
        throw herdrCompatLaunchError()
    }

    static func herdrCompatArguments(
        command: String,
        arguments: [String],
        jsonOutput: Bool = false
    ) -> [String]? {
        guard var prefix = herdrCompatCommands.first(where: { $0.name == command })?.arguments else {
            return nil
        }
        if command == "status", jsonOutput, !arguments.contains("--json") {
            prefix.append("--json")
        }
        return prefix + arguments
    }

    private static let herdrCompatCommands: [(name: String, arguments: [String])] = [
        ("status", ["status"]),
        ("snapshot", ["api", "snapshot"]),
        ("list-workspaces", ["workspace", "list"]),
        ("list-tabs", ["tab", "list"]),
        ("list-panes", ["pane", "list"]),
    ]

    private static var herdrCompatCommandList: String {
        herdrCompatCommands.map(\.name).joined(separator: ", ")
    }

    private func herdrCompatLaunchError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.herdrCompat.error.launchFailed",
                defaultValue: "Couldn't start the required command. Verify it is installed and try again."
            ),
            exitCode: 126
        )
    }

    private static func freeHerdrCompatArguments(_ arguments: [UnsafeMutablePointer<CChar>?]) {
        arguments.forEach { free($0) }
    }

    private static var herdrCompatUsage: String {
        let format = String(
            localized: "cli.herdrCompat.usage",
            defaultValue: """
            Usage: cmux __herdr-compat <command> [options]

            Hidden compatibility bridge to an installed Herdr CLI.
            Commands: %@
            """
        )
        return String(format: format, herdrCompatCommandList)
    }
}
