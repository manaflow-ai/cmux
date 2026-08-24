import Foundation

// `cmux subrouter`: control the local subrouter daemon's AI-agent accounts
// through the app. The CLI is presentation only; each verb maps to one
// `subrouter.*` socket method handled by the app-owned SubrouterStore (the
// single daemon-interaction path), so the Agents panel and footer switcher
// update immediately after a CLI switch or reload.
extension CMUXCLI {
    /// Leaves headroom for the app's socket deadline and a cold remote usage
    /// fan-out before the CLI gives up on a read-only subrouter verb.
    /// Must outlive the socket worker's full switch/reload/refresh pipeline:
    /// a 30s `sr` command plus two 60s daemon reads can legitimately take
    /// roughly 150s on a cold remote pool.
    private static let subrouterDataResponseTimeout: TimeInterval = 240

    static let subrouterUsage = """
        Usage: cmux subrouter [setup|status|accounts|usage|switch|sessions|reload] [--json]

          cmux subrouter
              First-run welcome: installs the sr CLI if missing, starts the
              configured daemon, and shows how to add accounts. Safe to re-run.

        Inspect and switch the AI-agent accounts managed by the configured
        subrouter daemon (local or remote). Requires the subrouter integration to
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
            let response = try client.sendV2(method: "subrouter.status", responseTimeout: Self.subrouterDataResponseTimeout)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printSubrouterStatus(response)

        case "accounts":
            let response = try client.sendV2(method: "subrouter.accounts", responseTimeout: Self.subrouterDataResponseTimeout)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printSubrouterAccounts(response, includeWindows: false)

        case "usage":
            let response = try client.sendV2(method: "subrouter.usage", responseTimeout: Self.subrouterDataResponseTimeout)
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
            // The app-side switch deadline is 90s (sr subprocess + daemon
            // reload + refresh); the client must outlive it or a slow
            // switch mutates credentials after the CLI reported a timeout.
            let response = try client.sendV2(
                method: "subrouter.switch",
                params: ["provider": positionals[0].lowercased(), "account": positionals[1]],
                responseTimeout: Self.subrouterDataResponseTimeout
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
            let response = try client.sendV2(method: "subrouter.sessions", responseTimeout: Self.subrouterDataResponseTimeout)
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
            let response = try client.sendV2(method: "subrouter.reload", responseTimeout: Self.subrouterDataResponseTimeout)
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
            try requireSubrouterIntegrationEnabled(client: client)
            try execSubrouter(persona: "sr", arguments: [sub] + rest)
        }
    }

    /// Prevents passthrough commands from bypassing the feature gate and
    /// mutating account state while the integration is disabled.
    func requireSubrouterIntegrationEnabled(client: SocketClient) throws {
        do {
            // Ask the running app for its effective remote feature-flag plus
            // user-setting gate without triggering a network refresh. This
            // keeps `cmux sr …` on the same control plane as the panel.
            _ = try client.sendV2(
                method: "subrouter.status",
                params: ["refresh": false],
                responseTimeout: 5
            )
            return
        } catch let error as CLIError where error.v2Code == "subrouter_disabled" {
            throw CLIError(message: String(
                localized: "cli.subrouter.disabled",
                defaultValue: "The subrouter integration is disabled. Enable it in Settings before running sr commands."
            ))
        } catch {
            // Fail closed when the app cannot answer: the release feature
            // flag and its safe default live in the app process, so a missing
            // or old socket must never become an authorization bypass.
            throw CLIError(message: String(
                localized: "cli.subrouter.gateUnavailable",
                defaultValue: "Cannot verify Subrouter integration. Open cmux, enable it in Settings, and retry."
            ))
        }
    }

    /// The bare `cmux subrouter` onboarding flow: install the sr CLI when
    /// missing from the bundled binary or an explicit user install, start the
    /// local daemon only when the configured endpoint is loopback, then show
    /// status plus how to add
    /// accounts. Idempotent —
    /// re-running on a healthy setup just prints status and next steps.
    private func runSubrouterWelcome(client: SocketClient) throws {
        try requireSubrouterIntegrationEnabled(client: client)
        print("cmux ⨯ subrouter — route agents across subscription accounts")
        print("")

        // 1. The sr CLI. Prefer installing from the app's own bundled
        // binary (offline, pinned to the submodule the app shipped with);
        // the remote installer is only the fallback for builds without it.
        // A managed ~/bin install is refreshed to this app's bundled
        // version before use.
        var srPath = resolveSubrouterBinaryRefreshingManagedInstall()
        if srPath == nil, let installed = installBundledSubrouterIntoHomeBin() {
            srPath = installed
            print("✓ Installed the bundled sr CLI (\(installed))")
        }
        if srPath == nil {
            print(String(
                localized: "cli.subrouter.install.manual",
                defaultValue: "subrouter is not installed. Install it explicitly from github.com/manaflow-ai/subrouter, then run cmux subrouter again."
            ))
        } else {
            print("✓ sr CLI installed (\(srPath ?? ""))")
        }

        // 2. The daemon, through the app (which follows sr's server selection).
        var statusResponse = try? client.sendV2(method: "subrouter.status", responseTimeout: Self.subrouterDataResponseTimeout)
        if statusResponse == nil {
            print("✗ The cmux subrouter integration is disabled.")
            print("  Enable it in Settings → Agent Accounts, or set {\"subrouter\": {\"enabled\": true}} in ~/.config/cmux/cmux.json.")
        } else if let daemon = statusResponse?["daemon"] as? [String: Any],
                  (daemon["state"] as? String) != "healthy",
                  let srPath {
            let endpoint = (statusResponse?["endpoint"] as? String) ?? ""
            guard Self.isLoopbackSubrouterEndpoint(endpoint) else {
                print(String(
                    localized: "cli.subrouter.remoteUnavailable",
                    defaultValue: "The configured remote subrouter is unavailable. Check the server connection and retry; cmux will not install a local daemon."
                ))
                return
            }
            print("Starting the local subrouter daemon…")
            let daemonSetup = CLIProcessRunner.runProcess(executablePath: srPath, arguments: ["install-daemon"], timeout: 60)
            if daemonSetup.status == 0 {
                // Poll the cheap health probe instead of the full status
                // refresh: stop as soon as the daemon reports healthy, and
                // give up after one aggregate five-second deadline.
                let readinessDeadline = Date(timeIntervalSinceNow: 5)
                for _ in 0..<10 {
                    waitForSubrouterReadinessInterval()
                    guard Date() < readinessDeadline else { break }
                    let probe = try? client.sendV2(
                        method: "subrouter.status",
                        params: ["probe": "health"],
                        responseTimeout: 4
                    )
                    if probe?["healthy"] as? Bool == true {
                        statusResponse = try? client.sendV2(
                            method: "subrouter.status",
                            responseTimeout: Self.subrouterDataResponseTimeout
                        )
                        break
                    }
                }
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
        print("  Ctrl+6 (or the sidebar Subrouter tab)   live usage and switching")
        print("  cmux subrouter usage                    quota windows per account")
        print("  cmux subrouter switch codex <email>     switch the active account")
        print("")
        print("Team server? `sr server add <name> --url <url> --default` — cmux follows sr's selection automatically.")
    }

    /// Gives the just-launched daemon a bounded half-second interval between
    /// readiness probes while keeping this synchronous CLI command responsive
    /// to the run-loop. The probe itself remains authoritative; the interval
    /// is only backoff, never the readiness signal.
    private func waitForSubrouterReadinessInterval() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
    }

    private static func isLoopbackSubrouterEndpoint(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
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
            if Self.isLoopbackSubrouterEndpoint(endpoint) {
                print("  hint:   install or start it with: ~/bin/subrouter install-daemon")
            } else {
                print("  hint:   check the configured remote server and retry")
            }
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
