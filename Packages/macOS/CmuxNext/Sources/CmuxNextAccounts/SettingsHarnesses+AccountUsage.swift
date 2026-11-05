import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Settings > Agents > Harnesses: each account's 5-hour and weekly usage at rest (Leo, 2026-11-05:
/// "i meant can you do all of htem", the accounts list's "show 5-hour and weekly usage per account
/// at rest"). Read when the page refreshes, never on a timer: one `_acpmux/account/usage` per
/// signed-in Codex account, all at once. Claude Code reports its limits only during a chat, so
/// Claude accounts are not asked.
extension SettingsHarnesses {
    /// The accounts whose usage the page asks for: signed-in Codex logins.
    nonisolated static func usageAccounts(_ accounts: [SettingsProviderAccount]) -> [String] {
        accounts.filter { $0.family == "codex" && $0.signedIn }.map(\.id)
    }

    /// The `usageLimits` of an `_acpmux/account/usage` reply; null when it read none (`skipped`, or
    /// Codex reported no plan limit).
    nonisolated static func usageLimits(_ data: Data) -> JSONValue {
        guard let limits = (try? JSONValue.parse(data))?["usageLimits"], limits["windows"]?.arrayValue != nil else {
            return .null
        }
        return limits
    }

    /// Reads every signed-in Codex account's usage at once. A read that fails (an older daemon, a
    /// Codex that did not answer) keeps what is shown for that account; only the newest refresh writes.
    func readAccountUsage(_ environment: AcpmuxEnvironment, generation mine: Int) async {
        let ids = Self.usageAccounts(accounts ?? [])
        guard !ids.isEmpty else {
            accountUsage = [:]
            return
        }
        let read = await withTaskGroup(of: (String, JSONValue?).self) { group in
            for id in ids {
                group.addTask { [self] in
                    let data = try? await callAccounts(environment, .accountUsage, ["id": id])
                    return (id, data.map(Self.usageLimits))
                }
            }
            var read: [String: JSONValue?] = [:]
            for await (id, limits) in group { read[id] = limits }
            return read
        }
        guard mine == generation else { return }
        var next: [String: JSONValue] = [:]
        for id in ids {
            if let limits = read[id] ?? nil { next[id] = limits } else if let shown = accountUsage[id] { next[id] = shown }
        }
        accountUsage = next
    }
}
