import Foundation

/// What the phone last saw from the live service for one account: the space
/// it used, that space's Macs, the Mac it linked to, and each Mac's
/// workspaces. Restored at launch so the screens show last-known data
/// (marked cached) and the link can dial before the service is asked anything.
public struct LiveSnapshot: Equatable, Sendable {
    public var teamID: String
    public var teamName: String
    public var macs: [MacDevice]
    /// The Mac the link last reached.
    public var linkedMacID: String?
    /// Mac id → its workspaces when it last answered, and when that was.
    public var workspaces: [String: MacWorkspaces]

    public struct MacWorkspaces: Equatable, Sendable {
        /// The Mac's cached workspaces: all of them, or (read at launch) only the first screen's,
        /// in the order the Workspaces list shows them.
        public var workspaces: [Workspace]
        public var savedAt: Date
        /// How many workspaces the cache holds for the Mac. More than `workspaces.count` while
        /// only the first screen's rows are read: the rest wait in the Mac's tail file.
        public var total: Int
        /// Names the tail file saved with these rows; a tail with another token is not theirs.
        public var tailToken: String?

        public init(workspaces: [Workspace], savedAt: Date, total: Int? = nil, tailToken: String? = nil) {
            self.workspaces = workspaces
            self.savedAt = savedAt
            self.total = max(total ?? workspaces.count, workspaces.count)
            self.tailToken = tailToken
        }

        /// Every cached row is here (not only the first screen's).
        public var isComplete: Bool { workspaces.count >= total }
    }

    public init(teamID: String, teamName: String, macs: [MacDevice], linkedMacID: String?, workspaces: [String: MacWorkspaces]) {
        self.teamID = teamID
        self.teamName = teamName
        self.macs = macs
        self.linkedMacID = linkedMacID
        self.workspaces = workspaces
    }

    /// One Mac's cached rows in the order the Workspaces list shows them for a cached Mac
    /// (`WorkspaceInbox`: nothing is shown as needing you, the pinned rows first in their pin
    /// order, then the rest newest first, which is the Mac's sidebar order when the Mac told it).
    /// The cache keeps its first rows in this order, so the first screen reads only them.
    public static func listOrder(_ rows: [Workspace]) -> [Workspace] {
        let pinned = rows.indices.filter { rows[$0].isPinned }
            .sorted { (rows[$0].pinIndex ?? .max, $0) < (rows[$1].pinIndex ?? .max, $1) }
        return pinned.map { rows[$0] } + newestFirst(rows.indices.filter { !rows[$0].isPinned }, rows).map { rows[$0] }
    }

    /// `WorkspaceInbox.newestFirst` over `indices` of `rows` (an offline Mac's fold shows its rows in this order).
    static func newestFirst(_ indices: [Int], _ rows: [Workspace]) -> [Int] {
        indices.sorted { i, j in
            let a = rows[i], b = rows[j]
            switch (a.sidebarIndex, b.sidebarIndex) {
            case let (x?, y?): return (a.macID, x) == (b.macID, y) ? i < j : (a.macID, x) < (b.macID, y)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): break
            }
            if a.hasActivityTime != b.hasActivityTime { return a.hasActivityTime }
            if a.hasActivityTime, a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
            if a.focusOrder != b.focusOrder { return a.focusOrder > b.focusOrder }
            return i < j
        }
    }
}

/// The Workspaces cache on disk, per account in Application Support, written off the main thread
/// (verify/persistence.md). Sign-out removes it all.
///
/// A launch reads only what the first screen shows: each Mac's first rows in list order live in
/// one small head file, the rest of each Mac's rows in a tail file of its own that is read after
/// the first frame (`loadRest`). So a Mac with 5,000 workspaces paints as fast as one with 20.
/// The format is versioned: a head of another version, or one that does not decode, deletes the
/// account's cache and the launch starts as with none; a tail that does not decode or belongs
/// to another head is dropped and the head's rows stay. Each Mac keeps at most `maxRowsPerMac`
/// rows, the last in list order go first.
public final class LiveSnapshotStore: @unchecked Sendable {
    /// The on-disk format. Bump it when `Head` or `Tail` change shape: older caches drop themselves.
    public static let formatVersion = 2
    /// Rows per Mac in the head file: a tall iPad's first screen, with room for pins.
    public static let firstScreenRows = 40
    /// Rows per Mac the cache keeps at most.
    public static let maxRowsPerMac = 5_000

    /// What the last `loadFirstScreen` read: the work the first frame waits on.
    public struct FirstScreenRead: Equatable, Sendable {
        public var bytes: Int
        public var rows: Int
    }

    private struct Head: Codable {
        var format: Int
        var teamID: String
        var teamName: String
        var macs: [MacDevice]
        var linkedMacID: String?
        var lists: [String: List]

        struct List: Codable {
            var rows: [Workspace]
            var total: Int
            var savedAt: Date
            var tail: String?
        }
    }

    private struct Tail: Codable {
        var format: Int
        var token: String
        var rows: [Workspace]
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "dev.cmux.mobile.snapshot", qos: .utility)
    private let lock = NSLock()
    private var firstScreenRead: FirstScreenRead?

    public init(directory: URL) {
        self.directory = directory
    }

    public static let standard: LiveSnapshotStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LiveSnapshotStore(directory: base.appending(path: "cmux-mobile-live", directoryHint: .isDirectory))
    }()

    public var lastFirstScreenRead: FirstScreenRead? { lock.withLock { firstScreenRead } }

    private static func safe(_ id: String) -> String {
        id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
    }

    private func accountDirectory(_ accountID: String) -> URL {
        directory.appending(path: "account-\(Self.safe(accountID))", directoryHint: .isDirectory)
    }

    private func headFile(_ accountID: String) -> URL { accountDirectory(accountID).appending(path: "head.json") }

    private func tailFile(_ accountID: String, macID: String) -> URL {
        accountDirectory(accountID).appending(path: "tail-\(Self.safe(macID)).json")
    }

    /// Format 1: the whole snapshot in one file. Not read; deleted when found.
    private func legacyFile(_ accountID: String) -> URL { directory.appending(path: "snapshot-\(Self.safe(accountID)).json") }

    /// The cache as the first screen needs it: the space, its Macs and each Mac's first rows in
    /// list order (`MacWorkspaces.total` says how many the Mac has). Reads one small file.
    /// Nil when there is no cache, or it is of another version or unreadable (it is then deleted).
    public func loadFirstScreen(accountID: String) -> LiveSnapshot? {
        let legacy = legacyFile(accountID)
        if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.removeItem(at: legacy) }
        guard let data = try? Data(contentsOf: headFile(accountID)) else { return nil }
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.format == Self.formatVersion else {
            try? FileManager.default.removeItem(at: accountDirectory(accountID))
            return nil
        }
        let lists = head.lists.mapValues {
            LiveSnapshot.MacWorkspaces(workspaces: $0.rows, savedAt: $0.savedAt, total: $0.total, tailToken: $0.tail)
        }
        lock.withLock { firstScreenRead = FirstScreenRead(bytes: data.count, rows: lists.values.reduce(0) { $0 + $1.workspaces.count }) }
        return LiveSnapshot(teamID: head.teamID, teamName: head.teamName, macs: head.macs,
                            linkedMacID: head.linkedMacID, workspaces: lists)
    }

    /// The rest of each Mac whose rows `snapshot` holds only the first screen of, read off the
    /// main thread: the Mac's whole cached list, first rows first. A Mac whose tail is gone,
    /// unreadable or another head's keeps its first rows, as a whole list of those. An unreadable
    /// tail is deleted; another head's (a save since `snapshot` was read) is left for that head.
    public func loadRest(_ snapshot: LiveSnapshot, accountID: String) async -> [String: LiveSnapshot.MacWorkspaces] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readRest(snapshot, accountID: accountID)) }
        }
    }

    private func readRest(_ snapshot: LiveSnapshot, accountID: String) -> [String: LiveSnapshot.MacWorkspaces] {
        var result: [String: LiveSnapshot.MacWorkspaces] = [:]
        for (macID, list) in snapshot.workspaces where !list.isComplete {
            let url = tailFile(accountID, macID: macID)
            var rows = list.workspaces
            if let data = try? Data(contentsOf: url) {
                if let tail = try? JSONDecoder().decode(Tail.self, from: data), tail.format == Self.formatVersion {
                    // Another token: a newer save's tail, named by the head now on disk. Not ours; it stays.
                    if tail.token == list.tailToken { rows += tail.rows }
                } else {
                    // Unreadable or another format (writes are atomic): nothing will read it.
                    try? FileManager.default.removeItem(at: url)
                }
            }
            result[macID] = LiveSnapshot.MacWorkspaces(workspaces: rows, savedAt: list.savedAt, tailToken: list.tailToken)
        }
        return result
    }

    /// The whole cache, every row (tests; the app reads `loadFirstScreen` and then `loadRest`).
    public func load(accountID: String) -> LiveSnapshot? {
        guard var snapshot = loadFirstScreen(accountID: accountID) else { return nil }
        let rest = queue.sync { readRest(snapshot, accountID: accountID) }
        for (macID, list) in rest { snapshot.workspaces[macID] = list }
        return snapshot
    }

    /// Saves `snapshot` off the main thread. A Mac whose rows are all here is written again
    /// (its first screen in the head, the rest in its tail); one that holds only its first
    /// screen (read at launch, its Mac not answered since) keeps the tail it has.
    public func save(_ snapshot: LiveSnapshot, accountID: String) {
        queue.async { self.write(snapshot, accountID: accountID) }
    }

    private func write(_ snapshot: LiveSnapshot, accountID: String) {
        let folder = accountDirectory(accountID)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        var lists: [String: Head.List] = [:]
        var tails: Set<String> = []
        for (macID, list) in snapshot.workspaces {
            let tailURL = tailFile(accountID, macID: macID)
            guard list.isComplete else {
                lists[macID] = Head.List(rows: list.workspaces, total: list.total, savedAt: list.savedAt, tail: list.tailToken)
                tails.insert(tailURL.lastPathComponent)
                continue
            }
            let ordered = Array(LiveSnapshot.listOrder(list.workspaces).prefix(Self.maxRowsPerMac))
            let (head, rest) = Self.split(ordered)
            var token: String?
            if !rest.isEmpty {
                let next = UUID().uuidString
                // The tail goes first: a head is never on disk before the tail it names.
                if let data = try? encoder.encode(Tail(format: Self.formatVersion, token: next, rows: rest)),
                   (try? data.write(to: tailURL, options: options)) != nil {
                    token = next
                    tails.insert(tailURL.lastPathComponent)
                }
            }
            // Without its tail the head says it is the whole list (`total` = its rows).
            lists[macID] = Head.List(rows: head, total: token == nil ? head.count : ordered.count, savedAt: list.savedAt, tail: token)
        }
        let head = Head(format: Self.formatVersion, teamID: snapshot.teamID, teamName: snapshot.teamName, macs: snapshot.macs,
                        linkedMacID: snapshot.linkedMacID, lists: lists)
        guard let data = try? encoder.encode(head) else { return }
        try? data.write(to: headFile(accountID), options: options)
        // Tails of Macs no longer listed, and of lists saved again without one.
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("tail-") && !tails.contains(name) {
            try? fileManager.removeItem(at: folder.appending(path: name))
        }
    }

    /// `ordered` (list order) cut into what the head keeps and the rest. The head keeps the
    /// first `firstScreenRows` rows of the list as a cached Mac shows it (pins first) and of an
    /// offline Mac's fold (newest first, pins among the rest), so either list's first screen
    /// is in the head. Rows keep their list order in both parts.
    static func split(_ ordered: [Workspace]) -> (head: [Workspace], rest: [Workspace]) {
        guard ordered.count > firstScreenRows else { return (ordered, []) }
        var keep = Set(0..<firstScreenRows)
        keep.formUnion(LiveSnapshot.newestFirst(Array(ordered.indices), ordered).prefix(firstScreenRows))
        var head: [Workspace] = []
        var rest: [Workspace] = []
        head.reserveCapacity(keep.count)
        rest.reserveCapacity(ordered.count - keep.count)
        for (index, row) in ordered.enumerated() {
            if keep.contains(index) { head.append(row) } else { rest.append(row) }
        }
        return (head, rest)
    }

    /// Waits for pending writes (tests).
    public func flush() {
        queue.sync {}
    }

    public func removeAll() {
        let directory = directory
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }
}
