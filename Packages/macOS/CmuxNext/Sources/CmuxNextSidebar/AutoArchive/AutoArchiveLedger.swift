public import Foundation

/// When this Mac last saw each workspace used (plans/cmux-next/auto-archive-DESIGN.md "Idle signal"),
/// the workspaces auto-archive archived itself, and the suggestion card's snooze. A value: the
/// coordinator owns one, and ``AutoArchiveLedgerStore`` loads and saves it.
public nonisolated struct AutoArchiveLedger: Codable, Equatable, Sendable {
    /// Last use by workspace id, seconds since 1970.
    public var seen: [String: Double] = [:]
    /// Document items auto-archive archived (they come back when shown); others keep Aziz's rule
    /// (an archived workspace opens dimmed).
    public var autoArchived: Set<String> = []
    /// No suggestion card before this time (Not Now), seconds since 1970.
    public var snoozedUntil: Double?

    public init() {}

    /// Records a use of `workspace` at `date` (the newer of the two wins).
    public mutating func saw(_ workspace: String, at date: Date) {
        let time = date.timeIntervalSince1970
        if seen[workspace].map({ $0 < time }) ?? true { seen[workspace] = time }
    }

    /// The last use of `workspace`, if recorded.
    public func lastSeen(_ workspace: String) -> Date? { seen[workspace].map(Date.init(timeIntervalSince1970:)) }

    /// Drops the records of workspaces that are gone, so the ledger stays as large as the sidebar.
    public mutating func keep(only workspaces: Set<String>, items: Set<String>) {
        seen = seen.filter { workspaces.contains($0.key) }
        autoArchived = autoArchived.intersection(items)
    }
}

/// Loads and saves the ``AutoArchiveLedger`` in one `UserDefaults` key (Repository). The defaults are
/// injected: the App passes `.standard`, tests a suite of their own. Main actor: `UserDefaults` is
/// not `Sendable`, and one small in-memory write every few minutes is cheaper than an actor hop
/// (UserDefaults persists off the main thread itself).
@MainActor
public final class AutoArchiveLedgerStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = "cmux.autoArchive.ledger") {
        self.defaults = defaults
        self.key = key
    }

    /// The saved ledger, or an empty one.
    public func load() -> AutoArchiveLedger {
        guard let data = defaults.data(forKey: key), let ledger = try? JSONDecoder().decode(AutoArchiveLedger.self, from: data) else {
            return AutoArchiveLedger()
        }
        return ledger
    }

    /// Saves `ledger`.
    public func save(_ ledger: AutoArchiveLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: key)
    }
}
