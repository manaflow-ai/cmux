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

    /// Reads every signed-in Codex account's usage at once, but not one whose read is still
    /// running (the daemon caches an answer only once it has it). A read that fails (an older
    /// daemon, a Codex that did not answer) keeps what is shown for that account; the newest
    /// refresh drops accounts no longer listed.
    func readAccountUsage(_ environment: AcpmuxEnvironment, generation mine: Int) async {
        let ids = Self.usageAccounts(accounts ?? [])
        let start = ids.filter { !usageReading.contains($0) }
        usageReading.formUnion(start)
        let read = await withTaskGroup(of: (String, JSONValue?).self) { group in
            for id in start {
                group.addTask { [self] in
                    let data = try? await callAccounts(environment, .accountUsage, ["id": id])
                    return (id, data.map(Self.usageLimits))
                }
            }
            var read: [String: JSONValue] = [:]
            for await (id, limits) in group { read[id] = limits }
            return read
        }
        usageReading.subtract(start)
        // One read per account at a time, so a read that outlived its refresh is still the newest.
        let listed = Set(Self.usageAccounts(accounts ?? []))
        for (id, limits) in read where listed.contains(id) { accountUsage[id] = limits }
        if mine == generation { accountUsage = accountUsage.filter { listed.contains($0.key) } }
    }
}
