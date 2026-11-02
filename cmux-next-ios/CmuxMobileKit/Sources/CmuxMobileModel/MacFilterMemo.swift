import Foundation

/// The Workspaces toolbar's per-Mac text, computed once per change instead of
/// on every body pass. The list's body reads the Mac names' disambiguation
/// (`MacNameDisambiguation`) for every row, subtitle and menu entry, and the
/// Filter menu formats every Mac's presence; with the account's 20-odd Macs
/// both were among the largest app frames of the first screens' main-thread
/// time (verify/perf-latency.md). Not observable: it only caches what the
/// body already read from the store.
@MainActor
public final class MacFilterMemo {
    /// One Filter menu row: the Mac's name ("Aziz's MacBook Pro 3F2A" when
    /// it shares the name: a menu row is text only, so the tag is spelled as
    /// in every other text) and its subtitle.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
    }

    /// Everything a Filter row's text depends on. `minute` makes offline
    /// Macs' "Last seen 4m ago" move on.
    public struct Input: Equatable {
        /// The clock's time the rows are formatted against; the cache keys on
        /// its minute (`minute`), not on this.
        public var now: Date
        public var macs: [MacDevice]
        /// Every Mac on the account (all teams): the tags' scope.
        public var accountMacs: [MacDevice]
        public var connection: [String: MacConnection]
        public var linkStatus: [String: String]
        public var live: Bool
        public var minute: Int

        public init(macs: [MacDevice], accountMacs: [MacDevice]? = nil, connection: [String: MacConnection],
                    linkStatus: [String: String], live: Bool, now: Date = Date()) {
            self.macs = macs
            self.accountMacs = accountMacs ?? macs
            self.connection = connection
            self.linkStatus = linkStatus
            self.live = live
            self.now = now
            minute = Int(now.timeIntervalSince1970 / 60)
        }

        public static func == (lhs: Input, rhs: Input) -> Bool {
            lhs.macs == rhs.macs && lhs.accountMacs == rhs.accountMacs && lhs.connection == rhs.connection
                && lhs.linkStatus == rhs.linkStatus && lhs.live == rhs.live && lhs.minute == rhs.minute
        }
    }

    private var namesKey: [MacDevice]?
    private var cachedNames = MacNameDisambiguation([MacDevice]())
    private var entriesKey: Input?
    private var cachedEntries: [Entry] = []
    /// How many times each was computed (tests).
    public private(set) var nameComputations = 0
    public private(set) var entryComputations = 0

    public init() {}

    private var rosterKey: [MacDevice]?
    private var cachedRoster = MacRoster([])

    /// ``MacRoster`` of `macs`, recomputed only when a Mac changed.
    public func roster(_ macs: [MacDevice]) -> MacRoster {
        if rosterKey == macs { return cachedRoster }
        rosterKey = macs
        cachedRoster = MacRoster(macs)
        return cachedRoster
    }

    /// The disambiguation for `macs` (pass the account's Macs), recomputed only when an id or a name changed.
    public func names(_ macs: [MacDevice]) -> MacNameDisambiguation {
        if let namesKey, namesKey.count == macs.count,
           zip(namesKey, macs).allSatisfy({ $0.id == $1.id && $0.name == $1.name }) {
            return cachedNames
        }
        namesKey = macs
        cachedNames = MacNameDisambiguation(macs)
        nameComputations += 1
        return cachedNames
    }

    /// The Filter menu's Mac rows (online first), recomputed only when `input` changed.
    public func entries(_ input: Input) -> [Entry] {
        if entriesKey == input { return cachedEntries }
        let names = names(input.accountMacs)
        let stamp = RelativeStamp(now: input.now)
        cachedEntries = MacScope.menuOrder(input.macs).map { mac in
            let presence = stamp.presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt)
            let status = MacStatusLine.make(mac: mac, connection: input.connection[mac.id], live: input.live, presence: presence).text
            let detail = input.linkStatus[mac.id] ?? status
            return Entry(id: mac.id, title: names.displayName(mac), detail: detail)
        }
        entriesKey = input
        entryComputations += 1
        return cachedEntries
    }
}
