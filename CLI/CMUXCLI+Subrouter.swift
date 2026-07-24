import Foundation

// `cmux subrouter`: control the local subrouter daemon's AI-agent accounts
// through the app. The CLI is presentation only; each verb maps to one
// `subrouter.*` socket method handled by the app-owned SubrouterStore (the
// single daemon-interaction path), so the Agents panel and footer switcher
// update immediately after a CLI switch or reload.
extension CMUXCLI {
    static let subrouterUsage = """
        Usage: cmux subrouter [setup|status|accounts|usage|switch|sessions|reload] [--json]

          cmux subrouter
              First-run welcome: installs the sr CLI if missing, starts the
              local daemon, and shows how to add accounts. Safe to re-run.

        Inspect and switch the AI-agent accounts managed by the local subrouter
        daemon (http://127.0.0.1:31415). Requires the subrouter integration to
        be enabled (Settings, or subrouter.enabled in ~/.config/cmux/cmux.json).

          cmux subrouter status [--json]
              Daemon reachability, endpoint, account/session counts.

          cmux subrouter accounts [--json]
              Configured accounts per provider with active/auth state.

          cmux subrouter usage [--json]
              Accounts with live quota windows (percent used, reset times)
              and cooked/temp-cooked state.

          cmux subrouter switch <codex|claude> <account> [--json]
              Switch the provider's active account via the sr CLI (Codex
              switches also update OpenCode and pi credentials), then reload
              the daemon. <account> is the Codex email or Claude profile name.

          cmux subrouter sessions [--json]
              Live agent-session → account pinning.

          cmux subrouter reload [--json]
              Ask the daemon to hot-reload its on-disk account store.

        Examples:
          cmux subrouter usage
          cmux subrouter switch codex dev@example.com
          cmux subrouter switch claude work
        """

    func runSubrouterNamespace(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let sub = commandArgs.first?.lowercased() else {
            try runSubrouterWelcome(client: client)
            return
        }
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.subrouterUsage)

        case "setup", "welcome", "install":
            try runSubrouterWelcome(client: client)

        case "status":
            let response = try client.sendV2(method: "subrouter.status")
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printSubrouterStatus(response)

        case "accounts":
            let response = try client.sendV2(method: "subrouter.accounts")
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printSubrouterAccounts(response, includeWindows: false)

        case "usage":
            let response = try client.sendV2(method: "subrouter.usage")
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printSubrouterAccounts(response, includeWindows: true)

        case "switch":
            let positionals = rest.filter { !$0.hasPrefix("-") }
            guard positionals.count == 2 else {
                throw CLIError(message: """
                    subrouter switch requires a provider and an account.

                      cmux subrouter switch codex dev@example.com
                      cmux subrouter switch claude work
                    """)
            }
            let response = try client.sendV2(
                method: "subrouter.switch",
                params: ["provider": positionals[0].lowercased(), "account": positionals[1]]
            )
            if jsonOutput {
                print(jsonString(response))
                return
            }
            print("Switched \(positionals[0].lowercased()) → \(positionals[1])")
            if let warning = response["warning"] as? String {
                print("  warning: \(warning)")
            }

        case "sessions":
            let response = try client.sendV2(method: "subrouter.sessions")
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let sessions = (response["sessions"] as? [[String: Any]]) ?? []
            if sessions.isEmpty {
                print("No active agent sessions.")
                return
            }
            for session in sessions {
                let agent = (session["agent_type"] as? String) ?? "?"
                let sessionID = (session["session_id"] as? String) ?? "?"
                let account = (session["account_id"] as? String) ?? "?"
                let updated = (session["updated_at"] as? String) ?? ""
                print("\(agent)  \(sessionID.prefix(16))  → \(account)  \(updated)")
            }

        case "reload":
            let response = try client.sendV2(method: "subrouter.reload")
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let accounts = (response["accounts"] as? Int) ?? 0
            let refreshed = (response["usage_refreshed"] as? Int) ?? 0
            print("Reloaded \(accounts) account(s), \(refreshed) usage score(s) refreshed.")

        default:
            // Anything else is an sr verb (add, list, pick, server, claude,
            // …): hand the whole invocation to the subrouter binary — the
            // user's PATH install when present, else the bundled one.
            try execSubrouter(persona: "sr", arguments: [sub] + rest)
        }
    }

    /// The bare `cmux subrouter` onboarding flow: install the sr CLI when
    /// missing (official checksummed installer), start the local daemon when
    /// unreachable, then show status plus how to add accounts. Idempotent —
    /// re-running on a healthy setup just prints status and next steps.
    private func runSubrouterWelcome(client: SocketClient) throws {
        print("cmux ⨯ subrouter — route agents across subscription accounts")
        print("")

        // 1. The sr CLI. Prefer installing from the app's own bundled
        // binary (offline, pinned to the submodule the app shipped with);
        // the remote installer is only the fallback for builds without it.
        var srPath = resolveSubrouterBinary()
        if srPath == nil, let installed = installBundledSubrouterIntoHomeBin() {
            srPath = installed
            print("✓ Installed the bundled sr CLI (\(installed))")
        }
        if srPath == nil {
            print("subrouter is not installed. Installing from github.com/manaflow-ai/subrouter…")
            let install = CLIProcessRunner.runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "curl -fsSL https://github.com/manaflow-ai/subrouter/releases/latest/download/install.sh | sh"],
                timeout: 120
            )
            if install.status == 0 {
                srPath = resolveSubrouterBinary()
                print("  ✓ Installed \(srPath ?? "~/bin/subrouter")")
            } else {
                let detail = install.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                print("  ✗ Install failed\(detail.isEmpty ? "" : ": \(detail.prefix(200))")")
                print("    Run it manually: curl -fsSL https://github.com/manaflow-ai/subrouter/releases/latest/download/install.sh | sh")
            }
        } else {
            print("✓ sr CLI installed (\(srPath ?? ""))")
        }

        // 2. The daemon, through the app (which follows sr's server selection).
        var statusResponse = try? client.sendV2(method: "subrouter.status")
        if statusResponse == nil {
            print("✗ The cmux subrouter integration is disabled.")
            print("  Enable it in Settings → Agent Accounts, or set {\"subrouter\": {\"enabled\": true}} in ~/.config/cmux/cmux.json.")
        } else if let daemon = statusResponse?["daemon"] as? [String: Any],
                  (daemon["state"] as? String) != "healthy",
                  let srPath {
            print("Starting the local subrouter daemon…")
            let daemonSetup = CLIProcessRunner.runProcess(executablePath: srPath, arguments: ["install-daemon"], timeout: 60)
            if daemonSetup.status == 0 {
                Thread.sleep(forTimeInterval: 1.5)
                statusResponse = try? client.sendV2(method: "subrouter.status")
            } else {
                print("  ✗ install-daemon failed; run `\(srPath) install-daemon` manually.")
            }
        }
        if let statusResponse {
            print("")
            printSubrouterStatus(statusResponse)
        }

        // 3. Next steps.
        let accountCount = (statusResponse?["account_count"] as? Int) ?? 0
        print("")
        if accountCount == 0 {
            print("Add your first accounts:")
        } else {
            print("Manage accounts:")
        }
        print("  sr import                    adopt your current ~/.codex login")
        print("  sr add                       add another Codex account (OAuth)")
        print("  sr                           interactive usage overview")
        print("")
        print("Then, in cmux:")
        print("  Ctrl+6 (or the sidebar Subrouter tab)   live usage, switching, sessions")
        print("  cmux subrouter usage                    quota windows per account")
        print("  cmux subrouter switch codex <email>     switch the active account")
        print("")
        print("Team server? `sr server add <name> --url <url> --default` — cmux follows sr's selection automatically.")
    }

    /// Mirrors the app's sr resolution order: explicit places first.
    func resolveSubrouterBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/bin/sr", "\(home)/bin/subrouter", "/opt/homebrew/bin/sr", "/usr/local/bin/sr"]
        if let pathVariable = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathVariable.split(separator: ":") {
                candidates.append("\(directory)/sr")
                candidates.append("\(directory)/subrouter")
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func printSubrouterStatus(_ response: [String: Any]) {
        let daemon = (response["daemon"] as? [String: Any]) ?? [:]
        let state = (daemon["state"] as? String) ?? "unknown"
        let endpoint = (response["endpoint"] as? String) ?? ""
        switch state {
        case "healthy":
            print("Daemon:   healthy (\(endpoint))")
        case "unreachable":
            let failures = (daemon["consecutive_failures"] as? Int) ?? 0
            print("Daemon:   unreachable (\(endpoint), \(failures) consecutive failure(s))")
            if let lastError = response["last_error"] as? String {
                print("  error:  \(lastError)")
            }
            print("  hint:   install or start it with: ~/bin/subrouter install-daemon")
        default:
            print("Daemon:   \(state) (\(endpoint))")
        }
        let accountCount = (response["account_count"] as? Int) ?? 0
        let attentionCount = (response["attention_count"] as? Int) ?? 0
        let sessionCount = (response["session_count"] as? Int) ?? 0
        if attentionCount > 0 {
            print("Accounts: \(accountCount) (\(attentionCount) need(s) attention)")
        } else {
            print("Accounts: \(accountCount)")
        }
        print("Sessions: \(sessionCount)")
        if let updated = response["last_updated"] as? String {
            print("Updated:  \(updated)")
        }
    }

    private func printSubrouterAccounts(_ response: [String: Any], includeWindows: Bool) {
        let accounts = (response["accounts"] as? [[String: Any]]) ?? []
        if accounts.isEmpty {
            print("No accounts configured. Add accounts with the sr CLI.")
            return
        }
        var lastProvider = ""
        for account in accounts {
            let provider = (account["provider"] as? String) ?? "?"
            if provider != lastProvider {
                print("\(provider):")
                lastProvider = provider
            }
            let id = (account["id"] as? String) ?? "?"
            let plan = (account["plan_type"] as? String) ?? ""
            let active = (account["active"] as? Bool) == true
            let quota = (account["quota"] as? String) ?? "ok"
            let authChecked = (account["auth_checked"] as? Bool) == true
            let authValid = (account["auth_valid"] as? Bool) == true
            var flags: [String] = []
            if active { flags.append("ACTIVE") }
            if quota == "cooked" { flags.append("COOKED") }
            if quota == "temp_cooked" { flags.append("COOLING") }
            if authChecked && !authValid { flags.append("AUTH-EXPIRED") }
            let flagText = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
            let planText = plan.isEmpty ? "" : "  (\(plan))"
            print("  \(id)\(planText)\(flagText)")
            if let error = account["error"] as? String, !error.isEmpty {
                print("      error: \(error)")
            }
            guard includeWindows else { continue }
            let windows = (account["windows"] as? [[String: Any]]) ?? []
            for window in windows {
                let name = (window["name"] as? String) ?? "?"
                let used = (window["used_percent"] as? Double) ?? 0
                let reset = (window["reset_after_seconds"] as? Int) ?? 0
                var line = "      \(name): \(Int(min(max(used, 0), 100).rounded()))% used"
                if reset > 0 {
                    line += ", resets in \(Self.subrouterDurationText(seconds: reset))"
                }
                print(line)
            }
            if let credits = account["credits"] as? [String: Any],
               (credits["has_credits"] as? Bool) == true,
               let balance = credits["balance"] as? String, !balance.isEmpty {
                print("      credits: \(balance)")
            }
        }
    }

    /// Formats seconds the way `sr` does: `2d 4h`, `3h 12m`, `<1m`.
    static func subrouterDurationText(seconds: Int) -> String {
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 && days == 0 { parts.append("\(minutes)m") }
        return parts.isEmpty ? "<1m" : parts.joined(separator: " ")
    }
}
