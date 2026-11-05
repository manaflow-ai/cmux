import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// A Claude Code login's plan, from `claude auth status --json` in its config folder (Leo,
/// 2026-11-05: "i meant can you do all of htem", the audit's "run `claude auth status` per config
/// folder when Settings or the picker opens (not from the daemon, so the keychain rule holds)").
///
/// acpmux lists Claude logins with no plan: on macOS the login is the keychain item, which the
/// daemon never reads on its own (cx-hh0vu). The app asks the CLI instead, only while the person has
/// Settings open, with `CLAUDE_CONFIG_DIR` set to an added account's folder. The CLI's answer names
/// `subscriptionType` (`pro`, `max`, `team`, `enterprise`) for a claude.ai login; only that word is
/// kept, never a token, and the email stays acpmux's.
nonisolated enum ClaudeAuthStatus {
    /// How long one `claude auth status` may take.
    static let timeout: Duration = .seconds(10)

    /// The plan of a `claude auth status --json` answer; nil when it is not a signed-in claude.ai login.
    static func plan(_ data: Data) -> String? {
        guard let root = try? JSONValue.parse(data), root["loggedIn"]?.boolValue == true,
              let plan = root["subscriptionType"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !plan.isEmpty else { return nil }
        return plan
    }

    /// Runs `<claude> auth status --json`, in `home` when it is an added account's folder.
    @concurrent static func run(claude: String, home: String?) async -> Data? {
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = home
        let request = ProcessRequest(URL(fileURLWithPath: claude), ["auth", "status", "--json"],
                                     environment: environment, timeout: timeout)
        // A signed-out login exits 1 and still answers its JSON.
        return try? await AsyncProcess().run(request).output
    }
}

extension SettingsHarnesses {
    /// The program acpmux's health check found for the Claude Code harness, absolute.
    var claudeProgram: String? {
        let path = health["claude"]?["path"]?.stringValue
        return path.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// Asks each signed-in Claude login for its plan (``ClaudeAuthStatus``), all at once. Only the
    /// newest refresh writes; a login whose answer names no plan keeps none.
    func readClaudePlans(generation mine: Int) async {
        guard let claude = claudeProgram, let accounts else { return }
        let logins = accounts.filter { $0.family == "claude" && $0.signedIn }.map { ($0.id, $0.home) }
        guard !logins.isEmpty else { return }
        let status = claudeStatus ?? { await ClaudeAuthStatus.run(claude: $0, home: $1) }
        let plans = await withTaskGroup(of: (String, String?).self) { group in
            for (id, home) in logins {
                group.addTask { (id, await status(claude, home).flatMap(ClaudeAuthStatus.plan)) }
            }
            var found: [String: String] = [:]
            for await (id, plan) in group { found[id] = plan }
            return found
        }
        guard mine == generation else { return }
        claudePlans = plans
    }
}
