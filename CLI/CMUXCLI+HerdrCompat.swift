import Darwin
import Foundation

extension CMUXCLI {
    /// Hidden compatibility bridge used while cmux grows native Herdr API parity.
    ///
    /// Keep this deliberately small: aliases are translated to Herdr's public CLI,
    /// then `exec` replaces cmux so stdout, stderr, signals, and exit status remain
    /// exactly those of Herdr.
    func runHerdrCompat(commandArgs: [String], jsonOutput: Bool) throws {
        var herdrCommandArgs = commandArgs
        var effectiveJSONOutput = jsonOutput
        // `--json` before the compatibility alias is a cmux presentation option.
        // Keep it accepted while preserving a later alias-local `--json` so the
        // JSON-only aliases can reject the provider's unsupported flag.
        while herdrCommandArgs.first == "--json" {
            effectiveJSONOutput = true
            herdrCommandArgs.removeFirst()
        }

        let usage = Self.herdrCompatUsage
        if herdrCommandArgs.first.map({ $0 == "--help" || $0 == "-h" }) ?? false {
            print(usage)
            return
        }

        guard let command = herdrCommandArgs.first else {
            throw CLIError(message: usage, exitCode: 2)
        }
        let arguments = Array(herdrCommandArgs.dropFirst())
        // Herdr accepts `--json` only on `status`. Alias-local `--json` on the
        // JSON-only aliases would be forwarded and rejected by the provider;
        // fail here with the compatibility usage instead.
        if Self.herdrCompatJSONOnlyCommandNames.contains(command), arguments.contains("--json") {
            throw CLIError(message: usage, exitCode: 2)
        }
        guard let translated = Self.herdrCompatArguments(
            command: command,
            arguments: arguments,
            jsonOutput: effectiveJSONOutput
        ) else {
            let format = String(
                localized: "cli.herdrCompat.error.unknownCommand",
                defaultValue: "Unknown compatibility command '%1$@'. Supported commands: %2$@.",
                bundle: Self.herdrCompatLocalizationBundle
            )
            throw CLIError(
                message: String(format: format, command, Self.herdrCompatCommandList),
                exitCode: 2
            )
        }
        guard let executable = resolveExecutableInSuppliedSearchPath(
            "herdr",
            searchPath: ProcessInfo.processInfo.environment["PATH"]
        ) else {
            throw herdrCompatLaunchError(exitCode: 127)
        }

        var cArguments: [UnsafeMutablePointer<CChar>?] = []
        for argument in [executable] + translated {
            guard let duplicated = strdup(argument) else {
                Self.freeHerdrCompatArguments(cArguments)
                throw herdrCompatLaunchError(exitCode: 126)
            }
            cArguments.append(duplicated)
        }
        cArguments.append(nil)
        defer { Self.freeHerdrCompatArguments(cArguments) }
        _ = cliExecFailureErrno {
            execv(executable, &cArguments)
        }
        throw herdrCompatLaunchError(exitCode: 126)
    }

    /// Translates a compatibility alias into the provider CLI arguments it owns.
    static func herdrCompatArguments(
        command: String,
        arguments: [String],
        jsonOutput: Bool = false
    ) -> [String]? {
        guard let prefix = herdrCompatCommands.first(where: { $0.name == command })?.arguments else {
            return nil
        }
        // Only `herdr status` has a distinct human vs JSON mode (`--json`).
        // `api snapshot`, `workspace list`, `tab list`, and `pane list` always emit JSON
        // and do not accept `--json`; injecting the flag there would fail those commands.
        // cmux `--json` is therefore intentionally a no-op for those aliases.
        let translated = prefix + arguments
        if command == "status", jsonOutput, !arguments.contains("--json") {
            return translated + ["--json"]
        }
        return translated
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

    private static var herdrCompatJSONOnlyCommandNames: Set<String> {
        Set(herdrCompatCommands.map(\.name).filter { $0 != "status" })
    }

    /// Catalog lives on the enclosing app bundle when the CLI is launched from
    /// `Contents/Resources/bin`; `Bundle.main` would miss those translations.
    private static var herdrCompatLocalizationBundle: Bundle {
        CLIExecutableLocator.enclosingAppBundle() ?? .main
    }

    /// Builds the provider-neutral error returned when discovery or launch fails.
    private func herdrCompatLaunchError(exitCode: Int32) -> CLIError {
        CLIError(
            message: String(
                localized: "cli.herdrCompat.error.launchFailed",
                defaultValue: "Couldn't start the required command. Verify it is installed and try again.",
                bundle: Self.herdrCompatLocalizationBundle
            ),
            exitCode: exitCode
        )
    }

    /// Releases an argv buffer that was allocated incrementally with `strdup`.
    private static func freeHerdrCompatArguments(_ arguments: [UnsafeMutablePointer<CChar>?]) {
        for argument in arguments {
            free(argument)
        }
    }

    private static var herdrCompatUsage: String {
        let format = String(
            localized: "cli.herdrCompat.usage",
            defaultValue: """
            Usage: cmux __herdr-compat <command> [options]

            Hidden compatibility bridge to an installed provider CLI.
            Commands: %@

            Notes:
              - `status` accepts cmux `--json` (mapped to provider `status --json`).
              - `snapshot`, `list-workspaces`, `list-tabs`, and `list-panes` always return JSON;
                a top-level cmux `--json` is accepted and ignored, while an alias-local
                `--json` is rejected.
            """,
            bundle: herdrCompatLocalizationBundle
        )
        return String(format: format, herdrCompatCommandList)
    }
}
