import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Pre-socket command dispatch
extension CMUXCLI {
    /// Handles commands dispatched before any socket path resolution.
    /// Returns true when the command was fully handled and run() should return.
    func runPreSocketEarlyCommand(
        command: String,
        commandArgs: [String],
        jsonOutput: Bool,
        socketPasswordArg: String?,
        explicitSocketPath: String?,
        cliBundleIdentifier: String?,
        processEnv: [String: String]
    ) throws -> Bool {
        if command == "version" {
            print(versionSummary())
            return true
        }

        // Check for --help/-h on subcommands before resolving sockets,
        // so help text is available even when cmux is not running.
        let preSeparatorArgs = commandArgs.firstIndex(of: "--").map { commandArgs[..<$0] } ?? commandArgs[...]
        if command != "__tmux-compat",
           preSeparatorArgs.contains(where: { $0 == "--help" || $0 == "-h" }) {
            if dispatchSubcommandHelp(command: command, commandArgs: commandArgs) {
                return true
            }
            print("Unknown command '\(command)'. Run 'cmux help' to see available commands.")
            return true
        }

        if command == "help" { print(usage()); return true }
        if command == "remote-daemon-status" { try runRemoteDaemonStatus(commandArgs: commandArgs, jsonOutput: jsonOutput); return true }
        if command == "vm-pty-connect" { try runVMPtyConnect(commandArgs: commandArgs); return true }
        if command == "docs" { try runDocsCommand(commandArgs: commandArgs, jsonOutput: jsonOutput); return true }
        if command == "welcome" { printWelcome(); return true }
        if command == "diff-viewer-server" { try runDiffViewerServerCommand(commandArgs: commandArgs); return true }

        if command == "settings",
           settingsCommandDoesNotNeedSocket(commandArgs) {
            try runSettings(
                commandArgs: commandArgs,
                socketPath: CLISocketPathResolver.defaultSocketPath(
                    bundleIdentifier: cliBundleIdentifier,
                    environment: processEnv
                ),
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return true
        }

        // Keep no-socket config subcommands on the early path. Socket-backed
        // config subcommands fall through to the resolved-socket dispatch below.
        if command == "config",
           configCommandDoesNotNeedSocket(commandArgs) {
            try runConfigCommand(
                commandArgs: commandArgs,
                socketPath: nil,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return true
        }

        // If the argument is a path (not a known command), open a workspace there.
        if shouldOpenAsPathArgument(command), explicitSocketPath == nil {
            try openPath(command)
            return true
        }
        return false
    }

    /// Handles commands that need the resolved socket path but dispatch before
    /// the shared SocketClient connection is established. Returns true when handled.
    func runPreSocketResolvedCommand(
        command: String,
        commandArgs: [String],
        jsonOutput: Bool,
        idFormatArg: String?,
        socketPasswordArg: String?,
        resolvedSocketPath: String,
        cliTelemetry: CLISocketSentryTelemetry,
        processEnv: [String: String]
    ) throws -> Bool {
        if shouldOpenAsPathArgument(command) {
            try openPathViaExplicitSocket(command, socketPath: resolvedSocketPath, explicitPassword: socketPasswordArg)
            return true
        }

        if command == "settings" {
            try runSettings(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return true
        }

        if command == "config" {
            try runConfigCommand(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return true
        }

        if command == "shortcuts" {
            try runShortcuts(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return true
        }
        if command == "open" { try runOpenCommand(commandArgs: commandArgs, socketPath: resolvedSocketPath, explicitPassword: socketPasswordArg, jsonOutput: jsonOutput, idFormat: try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)); return true }
        if command == "diff" { try runDiffCommand(commandArgs: commandArgs, socketPath: resolvedSocketPath, explicitPassword: socketPasswordArg, jsonOutput: jsonOutput, idFormat: try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)); return true }
        if command == "restore-session" {
            try runRestoreSession(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return true
        }

        if command == "feedback" {
            try runFeedback(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return true
        }

        if command == "right-sidebar" {
            let parsed = try parseRightSidebarCLIArguments(commandArgs)
            _ = try rightSidebarSocketArguments(from: parsed)
        }

        if command == "themes" {
            try runThemes(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        if command == "claude-teams" {
            try runClaudeTeams(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        if command == "codex-teams" {
            try runCodexTeams(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        if command == "omo" {
            try runOMO(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        if command == "omx" {
            try runOMX(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        if command == "__debug-tmux-compat-env" {
            try debugDumpTmuxCompatEnvironment(
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        if command == "omc" {
            try runOMC(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        if command == "codex" {
            // Backwards compatibility for old hook setup docs/scripts. Hidden from help.
            let sub = commandArgs.first?.lowercased() ?? "help"
            guard let codexDef = Self.agentDef(named: "codex") else { throw CLIError(message: "Codex hook integration is unavailable.") }
            if sub == "install-hooks" {
                try installHooksForAgent(codexDef, arguments: Array(commandArgs.dropFirst()))
                return true
            } else if sub == "uninstall-hooks" {
                try uninstallHooksForAgent(codexDef, arguments: Array(commandArgs.dropFirst()))
                return true
            }
        }
        if command == "setup-hooks" || command == "uninstall-hooks" { try runSetupHooks(uninstall: command == "uninstall-hooks"); return true } // Backwards compatibility for old hook setup docs/scripts.
        if (command == "codex-hook" || command == "feed-hook"), processEnv["CMUX_SURFACE_ID"]?.isEmpty != false, processEnv["CMUX_WORKSPACE_ID"]?.isEmpty != false,
           !commandArgs.contains(where: { $0 == "--workspace" || $0 == "--surface" || $0.hasPrefix("--workspace=") || $0.hasPrefix("--surface=") }) { print("{}"); return true } // Backwards compatibility for old installed hooks outside cmux terminals.
        if command == "hooks" {
            if try runHooksNoSocketCommand(commandArgs: commandArgs) {
                return true
            }
            if Self.hooksCommandNeedsCmuxTarget(commandArgs),
               processEnv["CMUX_SURFACE_ID"]?.isEmpty != false,
               processEnv["CMUX_WORKSPACE_ID"]?.isEmpty != false,
               !commandArgs.contains(where: { $0 == "--workspace" || $0 == "--surface" || $0.hasPrefix("--workspace=") || $0.hasPrefix("--surface=") }) {
                print("{}")
                return true
            }
            if commandArgs.first?.lowercased() == "feed" {
                try runFeedHook(
                    commandArgs: Array(commandArgs.dropFirst()),
                    socketPath: resolvedSocketPath,
                    socketPassword: socketPasswordArg,
                    telemetry: cliTelemetry
                )
                return true
            }
        }
        if command == "feed-hook" {
            try runFeedHook(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                socketPassword: socketPasswordArg,
                telemetry: cliTelemetry
            )
            return true
        }

        // Feed helpers: clear the persistent workstream history.
        if command == "feed" {
            let sub = commandArgs.first?.lowercased() ?? "help"
            switch sub {
            case "clear":
                try runFeedClear()
                return true
            case "tui":
                try runFeedTUI(
                    arguments: Array(commandArgs.dropFirst()),
                    socketPath: resolvedSocketPath,
                    socketPassword: socketPasswordArg
                )
                return true
            case "help", "--help", "-h":
                print("Usage: cmux feed tui [--opentui|--legacy]\n       cmux feed clear [--yes]")
                return true
            default:
                throw CLIError(message: "Unknown feed subcommand: \(sub)")
            }
        }

        if command == "events" {
            try runEventsCommand(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return true
        }

        let browserAvailabilityArgs = commandArgs.filter { $0 != "--json" }
        if command == "disable-browser" ||
            command == "enable-browser" ||
            command == "browser-status" ||
            (command == "browser" && ["disable", "enable", "status"].contains(browserAvailabilityArgs.first?.lowercased() ?? "")) {
            try runBrowserAvailabilityCommand(
                command: command,
                commandArgs: commandArgs,
                jsonOutput: jsonOutput,
                environment: processEnv
            )
            return true
        }

        try validateSurfaceResumeCommandValueOptionsBeforeSocket(
            command: command,
            commandArgs: commandArgs
        )
        return false
    }
}
