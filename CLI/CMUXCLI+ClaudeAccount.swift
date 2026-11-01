import CMUXAgentLaunch
import CmuxFoundation
import Foundation

/// `cmux claude-account`: list the registered Claude Code accounts, or move a Claude terminal
/// to another one and continue the same conversation there.
extension CMUXCLI {
    static var claudeAccountUsage: String {
        String(
            localized: "cli.claudeAccount.usage",
            defaultValue: "Usage: cmux claude-account [list] [--json]\n       cmux claude-account switch <name> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--force] [--json]"
        )
    }

    static var claudeAccountHelp: String {
        claudeAccountUsage + "\n\n" + String(localized: "cli.claudeAccount.help", defaultValue: """
        list: print the registered Claude Code accounts (agents.claudeAccounts in cmux.json, plus the default ~/.claude account). Works without a running cmux.

        switch <name>: move a Claude terminal to that account and continue the same conversation there. The terminal restarts under the account and cmux types the resume command. It switches the calling terminal unless --surface names another. --force also switches while Claude is responding, which stops the response.

        <surface> is a UUID, a ref like surface:3, or an index with --workspace.
        """)
    }

    /// Only `switch` talks to the app; `list` reads cmux.json directly, so it works while cmux
    /// is not running.
    static func claudeAccountCommandNeedsSocket(_ commandArgs: [String]) -> Bool {
        commandArgs.first?.lowercased() == "switch"
    }

    /// `cmux claude-account [list]`: the accounts from the user `cmux.json` and the nearest
    /// project `.cmux/cmux.json` above the current directory, default account first.
    func runClaudeAccountList(commandArgs: [String], jsonOutput: Bool) throws {
        guard commandArgs.count <= 1, commandArgs.first.map({ $0.lowercased() == "list" }) ?? true else {
            throw CLIError(message: Self.claudeAccountUsage)
        }
        let home = NSHomeDirectory()
        let registry = ClaudeAccountRegistry.load(
            homeDirectory: home,
            workingDirectory: FileManager.default.currentDirectoryPath,
            sanitize: { try JSONCParser.preprocess(data: $0) }
        )
        if jsonOutput {
            let accounts: [[String: Any]] = registry.accounts.map { account in
                [
                    "name": account.name,
                    "config_dir": account.exhaustionKey(homeDirectory: home),
                    "default": account.isDefault,
                ]
            }
            print(jsonString(["accounts": accounts]))
            return
        }
        let nameWidth = registry.accounts.map(\.name.count).max() ?? 0
        let defaultMarker = String(localized: "cli.claudeAccount.list.defaultMarker", defaultValue: "(default)")
        for account in registry.accounts {
            let name = account.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let directory = Self.claudeAccountDisplayPath(account.exhaustionKey(homeDirectory: home), home: home)
            print(account.isDefault ? "\(name)  \(directory)  \(defaultMarker)" : "\(name)  \(directory)")
        }
    }

    /// `cmux claude-account switch <name>`. The app checks the account, the pane and its Claude
    /// session and says why it refused, so the CLI only resolves the target.
    func runClaudeAccount(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard Self.claudeAccountCommandNeedsSocket(commandArgs) else {
            throw CLIError(message: Self.claudeAccountUsage)
        }
        let (workspaceOption, afterWorkspace) = parseOption(Array(commandArgs.dropFirst()), name: "--workspace")
        let (surfaceOption, afterSurface) = parseOption(afterWorkspace, name: "--surface")
        let force = afterSurface.contains("--force")
        let positional = afterSurface.filter { $0 != "--force" }
        guard positional.count == 1, let accountName = positional.first,
              !accountName.hasPrefix("-"),
              !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: Self.claudeAccountUsage)
        }

        // The calling terminal by default. Otherwise --surface must name one (the app requires
        // surface_id), so a typo never restarts whichever pane happens to be focused.
        let callerSurface = ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let surfaceRaw = surfaceOption ?? (workspaceOption == nil ? callerSurface : nil),
              !surfaceRaw.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.claudeAccount.error.noTarget",
                defaultValue: "No terminal to switch: run this inside a cmux terminal, or pass --surface."
            ))
        }

        var params: [String: Any] = ["account": accountName, "force": force]
        let workspaceId = try normalizeWorkspaceHandle(
            workspaceOption ?? Self.callerWorkspaceForSurfaceHandle(surfaceRaw, windowRaw: nil),
            client: client
        )
        if let workspaceId { params["workspace_id"] = workspaceId }
        guard let surfaceId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceId) else {
            throw CLIError(message: Self.claudeAccountUsage)
        }
        params["surface_id"] = surfaceId

        // The switch waits for the old Claude to exit and the new shell's prompt. A refusal such
        // as agent_running already explains itself, including how to force the switch.
        let response = try client.sendV2(method: "claude_account.switch", params: params, responseTimeout: 90)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print(String(
            format: String(localized: "cli.claudeAccount.switched", defaultValue: "OK switched %1$@ from %2$@ to %3$@"),
            surfaceOption ?? (response["surface_id"] as? String) ?? surfaceRaw,
            (response["from"] as? String) ?? "",
            (response["to"] as? String) ?? accountName
        ))
        guard response["resumed"] as? Bool == false, let command = response["resume_command"] as? String else {
            return
        }
        let explanation: String
        if response["not_resumed_reason"] as? String == "previous_claude_running" {
            explanation = String(
                localized: "cli.claudeAccount.previousClaudeStillRunning",
                defaultValue: "The previous Claude is still running, so cmux didn't resume the conversation: it would run in two places. Once that Claude has quit, run this command in that terminal:"
            )
        } else if response["pane_closed"] as? Bool == true {
            explanation = String(
                localized: "cli.claudeAccount.resumeManuallyPaneClosed",
                defaultValue: "The terminal was closed before cmux could resume the conversation. To continue it, run this command in a terminal:"
            )
        } else {
            explanation = String(
                localized: "cli.claudeAccount.resumeManually",
                defaultValue: "cmux couldn't resume the conversation automatically. To continue it, run this command in that terminal:"
            )
        }
        print("\n\(explanation)\n\n\(command)")
    }

    /// `~/…` for a directory under `home`, the absolute path otherwise.
    static func claudeAccountDisplayPath(_ directory: String, home: String) -> String {
        let standardizedHome = (home as NSString).standardizingPath
        guard directory.hasPrefix(standardizedHome + "/") else { return directory }
        return "~" + directory.dropFirst(standardizedHome.count)
    }
}
