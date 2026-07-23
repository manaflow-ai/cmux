import Darwin
import Foundation

extension CMUXCLI {
    /// Hidden compatibility bridge used while cmux grows native Herdr API parity.
    ///
    /// Keep this deliberately small: aliases are translated to Herdr's public CLI,
    /// then `exec` replaces cmux so stdout, stderr, signals, and exit status remain
    /// exactly those of Herdr.
    func runHerdrCompat(commandArgs: [String], jsonOutput: Bool) throws {
        if commandArgs.first.map({ $0 == "--help" || $0 == "-h" }) ?? false {
            print(Self.herdrCompatUsage)
            return
        }

        guard let command = commandArgs.first else {
            throw CLIError(message: Self.herdrCompatUsage, exitCode: 2)
        }
        guard let translated = Self.herdrCompatArguments(
            command: command,
            arguments: Array(commandArgs.dropFirst()),
            jsonOutput: jsonOutput
        ) else {
            throw CLIError(
                message: "Unknown __herdr-compat command '\(command)'. Supported commands: status, snapshot, list-workspaces, list-tabs, list-panes.",
                exitCode: 2
            )
        }
        guard let executable = Self.resolveHerdrExecutable() else {
            throw CLIError(
                message: "Herdr was not found. Install it and make sure \"herdr\" is available on PATH.",
                exitCode: 127
            )
        }

        let argv = [executable] + translated
        var cArguments = argv.map { strdup($0) } + [nil]
        defer { cArguments.dropLast().forEach { free($0) } }
        let code = cliExecFailureErrno {
            execv(executable, &cArguments)
        }
        throw CLIError(
            message: "Failed to launch Herdr at \(executable): \(String(cString: strerror(code)))",
            exitCode: 126
        )
    }

    static func herdrCompatArguments(
        command: String,
        arguments: [String],
        jsonOutput: Bool = false
    ) -> [String]? {
        let prefix: [String]
        switch command {
        case "status":
            prefix = ["status"] + (jsonOutput && !arguments.contains("--json") ? ["--json"] : [])
        case "snapshot":
            prefix = ["api", "snapshot"]
        case "list-workspaces":
            prefix = ["workspace", "list"]
        case "list-tabs":
            prefix = ["tab", "list"]
        case "list-panes":
            prefix = ["pane", "list"]
        default:
            return nil
        }
        return prefix + arguments
    }

    static func resolveHerdrExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? fileManager.currentDirectoryPath : String(directory)
            let candidate = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent("herdr", isDirectory: false).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static let herdrCompatUsage = """
    Usage: cmux __herdr-compat <command> [options]

    Hidden compatibility bridge to an installed Herdr CLI.
    Commands: status, snapshot, list-workspaces, list-tabs, list-panes
    """
}
