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


// MARK: - Agent hooks, tmux compat, browser, and misc command dispatch
extension CMUXCLI {
    /// Handles agent hook, tmux-compat, browser, project, and markdown socket commands.
    /// Returns true when the command matched; false to let the next dispatcher try.
    func runAgentHooksMiscCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowId: String?,
        socketPasswordArg: String?,
        cliTelemetry: CLISocketSentryTelemetry
    ) throws -> Bool {
        switch command {
        case "claude-hook":
            cliTelemetry.breadcrumb("claude-hook.dispatch")
            do {
                try runClaudeHook(commandArgs: commandArgs, client: client, telemetry: cliTelemetry, socketPassword: socketPasswordArg)
                cliTelemetry.breadcrumb("claude-hook.completed")
            } catch {
                cliTelemetry.breadcrumb("claude-hook.failure")
                captureSocketTransportError(telemetry: cliTelemetry, stage: "claude_hook_dispatch", error: error, client: client)
                throw error
            }
        case "codex-hook": // Backwards compatibility for older installed Codex hooks. Hidden from help.
            guard let codexDef = Self.agentDef(named: "codex") else { print("{}"); return true }
            try runGenericAgentHook(def: codexDef, commandArgs: commandArgs, client: client, telemetry: cliTelemetry, socketPassword: socketPasswordArg)
        case "feed-hook": // Backwards compatibility for older installed Feed hooks. Hidden from help.
            try runFeedHook(commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
        case "hooks":
            try runHooksSocketCommand(commandArgs: commandArgs, client: client, telemetry: cliTelemetry, socketPassword: socketPasswordArg)

        case "set-app-focus":
            guard let value = commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
            let response = try sendV1Command("set_app_focus \(value)", client: client)
            print(response)

        case "simulate-app-active":
            let response = try sendV1Command("simulate_app_active", client: client)
            print(response)

        case "__tmux-compat":
            try runClaudeTeamsTmuxCompat(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "__codex-teams-watch":
            try runCodexTeamsWatcher(commandArgs: commandArgs, client: client, socketPassword: socketPasswordArg)

        case "capture-pane",
             "resize-pane",
             "pipe-pane",
             "wait-for",
             "swap-pane",
             "break-pane",
             "join-pane",
             "last-window",
             "last-pane",
             "next-window",
             "previous-window",
             "find-window",
             "clear-history",
             "set-hook",
             "popup",
             "bind-key",
             "unbind-key",
             "copy-mode",
             "set-buffer",
             "paste-buffer",
             "list-buffers",
             "respawn-pane",
             "display-message":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "help":
            print(usage())

        // Browser commands
        case "browser":
            try runBrowserCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Project pane
        case "project":
            try runProjectCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Legacy aliases shimmed onto the v2 browser command surface.
        case "open-browser":
            try runBrowserCommand(commandArgs: ["open"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "navigate":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["navigate"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-back":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["back"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-forward":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["forward"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-reload":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["reload"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "get-url":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["get-url"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-webview":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["focus-webview"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "is-webview-focused":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["is-webview-focused"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Markdown commands
        case "markdown":
            try runMarkdownCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            return false
        }
        return true
    }
}
