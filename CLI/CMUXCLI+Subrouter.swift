import Foundation

// `cmux subrouter`: control the local subrouter daemon's AI-agent accounts
// through the app. The CLI is presentation only; each verb maps to one
// `subrouter.*` socket method handled by the app-owned SubrouterStore (the
// single daemon-interaction path), so the Agents panel and footer switcher
// update immediately after a CLI switch or reload.
extension CMUXCLI {
    static let subrouterUsage = """
        Usage: cmux subrouter <status|accounts|usage|switch|sessions|reload> [--json]

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
            throw CLIError(message: "subrouter requires a subcommand. Try: status, accounts, usage, switch, sessions, reload")
        }
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.subrouterUsage)

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
            throw CLIError(message: "Unknown subrouter subcommand: \(sub). Try: status, accounts, usage, switch, sessions, reload")
        }
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
