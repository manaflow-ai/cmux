public import CmuxNextDaemon
public import Foundation
public import Observation

/// Which OSC 7501 `done` and `error` records this client has seen
/// (contract .cmux-scratch/nx-osc7501/CONTRACT.md: "until seen" is client
/// view state; the daemon keeps the record). A key is the terminal, the
/// record id and its `updated_seq`, so a new report of the same record is
/// unseen again. `working`, `blocked` and `idle` are live states and are
/// never hidden. Pure.
public nonisolated struct ProgramStatusSeen: Hashable, Sendable {
    struct Key: Hashable, Sendable, Codable {
        var terminal: String
        var record: String
        var updatedSeq: UInt64
    }

    /// At most this many keys; the oldest leave first. Keys of records that
    /// left their terminal are pruned when that terminal is seen again; the
    /// limit bounds the keys of terminals that closed.
    static let limit = 1024

    /// Oldest first.
    private(set) var keys: [Key] = []

    public init() {}

    init(keys: [Key]) {
        self.keys = Array(keys.suffix(Self.limit))
    }

    var count: Int { keys.count }

    /// The records still to show: every record except a seen `done` or `error`.
    public func visible(_ records: [ProgramStatusRecord], terminal: String) -> [ProgramStatusRecord] {
        guard !keys.isEmpty else { return records }
        let seen = Set(keys)
        return records.filter { !Self.holdsUntilSeen($0) || !seen.contains(Self.key($0, terminal: terminal)) }
    }

    /// Marks the terminal's current `done` and `error` records seen and drops
    /// the terminal's keys of records it no longer has. Returns whether the
    /// set changed.
    @discardableResult
    public mutating func markSeen(_ records: [ProgramStatusRecord], terminal: String) -> Bool {
        let current = records.filter(Self.holdsUntilSeen).map { Self.key($0, terminal: terminal) }
        let currentSet = Set(current)
        var next = keys.filter { $0.terminal != terminal || currentSet.contains($0) }
        let present = Set(next)
        next.append(contentsOf: current.filter { !present.contains($0) })
        if next.count > Self.limit { next.removeFirst(next.count - Self.limit) }
        guard next != keys else { return false }
        keys = next
        return true
    }

    static func holdsUntilSeen(_ record: ProgramStatusRecord) -> Bool {
        record.state == .done || record.state == .error
    }

    static func key(_ record: ProgramStatusRecord, terminal: String) -> Key {
        Key(terminal: terminal, record: record.id, updatedSeq: record.updatedSeq)
    }
}

/// This client's seen set for OSC 7501 records. `StatusMapping` reads it;
/// the notification service marks a tab seen when the user focuses, types
/// in, clicks or opens it. Observable, so a look redraws exactly the tabs and
/// rows that read it. Kept in the user defaults the app passes to `persist`
/// (tests keep it in memory), so a relaunch does not show old marks again.
@Observable @MainActor
public final class ProgramStatusSeenStore {
    public static let shared = ProgramStatusSeenStore()

    static let defaultsKey = "cmux.next.programStatusSeen.v1"

    public private(set) var seen = ProgramStatusSeen()
    @ObservationIgnored private var defaults: UserDefaults?

    public init() {}

    /// Loads the saved set from `defaults` and saves every change there.
    public func persist(to defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let keys = try? JSONDecoder().decode([ProgramStatusSeen.Key].self, from: data) {
            seen = ProgramStatusSeen(keys: keys)
        }
    }

    /// The terminal key of a tab: its terminal resource, else the tab.
    public static func terminal(of tab: TabModel) -> String {
        tab.terminalResourceID.map { "terminal:\($0.rawValue)" } ?? "tab:\(tab.id)"
    }

    public func visible(_ records: [ProgramStatusRecord], terminal: String) -> [ProgramStatusRecord] {
        seen.visible(records, terminal: terminal)
    }

    /// The records of `tab` still to show.
    public func visible(_ tab: TabModel) -> [ProgramStatusRecord] {
        tab.programStatus.isEmpty ? [] : seen.visible(tab.programStatus, terminal: Self.terminal(of: tab))
    }

    public func markSeen(_ records: [ProgramStatusRecord], terminal: String) {
        var next = seen
        guard next.markSeen(records, terminal: terminal) else { return }
        seen = next
        save()
    }

    /// The user looked at `tab`: its `done` and `error` records are seen.
    public func markSeen(_ tab: TabModel) {
        // A tab without records and without saved keys has nothing to clear.
        let terminal = Self.terminal(of: tab)
        guard !tab.programStatus.isEmpty || seen.keys.contains(where: { $0.terminal == terminal }) else { return }
        markSeen(tab.programStatus, terminal: terminal)
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(seen.keys) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
