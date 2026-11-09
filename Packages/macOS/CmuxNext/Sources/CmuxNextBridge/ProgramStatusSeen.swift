import CmuxNextCompat
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
    private(set) var keys: [Key] = [] {
        didSet { (keySet, keysPerTerminal) = Self.index(keys) }
    }
    /// ``keys`` as a set, and how many keys each terminal has: a look that changes nothing (every
    /// keystroke in a terminal marks its tab seen) is answered from these in O(the tab's records),
    /// not O(``limit``). Derived from ``keys`` only.
    private var keySet: Set<Key> = []
    private var keysPerTerminal: [String: Int] = [:]

    public init() {}

    init(keys: [Key]) {
        self.keys = Array(keys.suffix(Self.limit))
        (keySet, keysPerTerminal) = Self.index(self.keys)
    }

    private static func index(_ keys: [Key]) -> (Set<Key>, [String: Int]) {
        (Set(keys), keys.reduce(into: [:]) { $0[$1.terminal, default: 0] += 1 })
    }

    /// Seen keys ``markSeen(_:terminal:)`` read since this value was made: its cost, which tests count (a look
    /// that changes nothing must read the tab's records, not every key). Not part of the value (`==`, `hash`).
    private(set) var keysRead = 0

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.keys == rhs.keys }
    public func hash(into hasher: inout Hasher) { hasher.combine(keys) }

    var count: Int { keys.count }

    /// Whether any key is `terminal`'s, in O(1).
    public func hasKeys(of terminal: String) -> Bool { keysPerTerminal[terminal, default: 0] > 0 }

    /// The records still to show: every record except a seen `done` or `error`.
    public func visible(_ records: [ProgramStatusRecord], terminal: String) -> [ProgramStatusRecord] {
        guard !keys.isEmpty else { return records }
        return records.filter { !Self.holdsUntilSeen($0) || !keySet.contains(Self.key($0, terminal: terminal)) }
    }

    /// Marks the terminal's current `done` and `error` records seen and drops
    /// the terminal's keys of records it no longer has. Returns whether the
    /// set changed.
    @discardableResult
    public mutating func markSeen(_ records: [ProgramStatusRecord], terminal: String) -> Bool {
        let current = records.filter(Self.holdsUntilSeen).map { Self.key($0, terminal: terminal) }
        let currentSet = Set(current)
        // Already seen, and no key of a record the terminal no longer has: nothing changes.
        keysRead += currentSet.count  // the lookups of the check below
        if currentSet.count == keysPerTerminal[terminal, default: 0], currentSet.isSubset(of: keySet) { return false }
        keysRead += keys.count  // the rebuild reads every key
        var next = keys.filter { $0.terminal != terminal || currentSet.contains($0) }
        let present = Set(next)
        next.append(contentsOf: current.filter { !present.contains($0) })
        if next.count > Self.limit { next.removeFirst(next.count - Self.limit) }
        guard next != keys else { return false }
        keys = next
        return true
    }

    /// The terminals whose keys differ from `old`'s after a ``markSeen(_:terminal:)`` of `terminal`: it, and those
    /// whose oldest keys the limit pushed out. O(1) unless the set is full (only then can a key leave another terminal).
    func terminals(changedFrom old: Self, marking terminal: String) -> Set<String> {
        var changed: Set<String> = [terminal]
        guard keys.count >= Self.limit else { return changed }
        for (other, count) in old.keysPerTerminal where other != terminal && keysPerTerminal[other, default: 0] != count {
            changed.insert(other)
        }
        return changed
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

    /// Not observed as one value: a reader observes its terminal's revision (`revisions`), so a look at one tab
    /// redraws the tabs and rows of that terminal only, not every row that shows a program status.
    @ObservationIgnored public private(set) var seen = ProgramStatusSeen()
    /// Bumped per terminal whose seen keys changed; read by each lookup of that terminal.
    private let revisions = ObservedMap<String, UInt64>()
    /// Bumped when the whole set is loaded (`persist`): every reader reads it again.
    private var loads: UInt64 = 0
    @ObservationIgnored private var defaults: UserDefaults?

    public init() {}

    /// Loads the saved set from `defaults` and saves every change there.
    public func persist(to defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let keys = try? JSONDecoder().decode([ProgramStatusSeen.Key].self, from: data) {
            seen = ProgramStatusSeen(keys: keys)
            loads &+= 1
        }
    }

    /// The terminal key of a tab: its terminal resource, else the tab.
    public static func terminal(of tab: TabModel) -> String {
        tab.terminalResourceID.map { "terminal:\($0.rawValue)" } ?? "tab:\(tab.id)"
    }

    public func visible(_ records: [ProgramStatusRecord], terminal: String) -> [ProgramStatusRecord] {
        observe(terminal)
        return seen.visible(records, terminal: terminal)
    }

    /// The records of `tab` still to show.
    public func visible(_ tab: TabModel) -> [ProgramStatusRecord] {
        guard !tab.programStatus.isEmpty else { return [] }
        let terminal = Self.terminal(of: tab)
        observe(terminal)
        return seen.visible(tab.programStatus, terminal: terminal)
    }

    /// Observes `terminal`'s seen keys only (and a load of the whole set).
    private func observe(_ terminal: String) {
        _ = loads
        _ = revisions[terminal]
    }

    public func markSeen(_ records: [ProgramStatusRecord], terminal: String) {
        var next = seen
        guard next.markSeen(records, terminal: terminal) else { return }
        // The terminal marked, and any whose oldest keys the limit pushed out.
        let changed = next.terminals(changedFrom: seen, marking: terminal)
        seen = next
        for terminal in changed { revisions[terminal] = (revisions[terminal] ?? 0) &+ 1 }
        save()
    }

    /// The user looked at `tab`: its `done` and `error` records are seen.
    public func markSeen(_ tab: TabModel) {
        // A tab without records and without saved keys has nothing to clear.
        let terminal = Self.terminal(of: tab)
        guard !tab.programStatus.isEmpty || seen.hasKeys(of: terminal) else { return }
        markSeen(tab.programStatus, terminal: terminal)
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(seen.keys) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// One viewed tab, its OSC 7501 records and whether it holds an unread
/// notification (NotificationCenterService `viewedFacts`).
public struct ViewedProgramStatus: Equatable, Sendable {
    public var tab: String
    public var records: [ProgramStatusRecord]
    public var unread: Bool
    public init(tab: String, records: [ProgramStatusRecord], unread: Bool = false) {
        (self.tab, self.records, self.unread) = (tab, records, unread)
    }
}

/// The viewed tabs' facts and the revision of which tabs are viewed (bumped
/// when a window's settled focus changes).
public struct ViewedTabsFacts: Equatable, Sendable {
    public var revision: UInt64
    public var tabs: [ViewedProgramStatus]
    public init(revision: UInt64, tabs: [ViewedProgramStatus]) { (self.revision, self.tabs) = (revision, tabs) }
}
