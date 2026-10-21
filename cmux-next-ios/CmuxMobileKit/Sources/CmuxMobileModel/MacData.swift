import Foundation

/// What the phone knows about one Mac's workspaces, and where it came from.
///
/// The screens must never say "No workspaces" (or any other empty state)
/// before the Mac itself answered: while the link connects they show the
/// last-known list from the snapshot, marked as cached, or a skeleton when
/// there is none. Events in, `phase` out; `LiveCoordinator` feeds it and
/// the Workspaces list reads `phase`.
public struct MacDataMachine: Equatable, Sendable {
    /// Where the workspaces on screen came from.
    public enum Source: Equatable, Sendable {
        /// Nothing yet.
        case none
        /// The snapshot saved when the Mac last answered (or the live list
        /// kept after the link dropped).
        case cache(savedAt: Date)
        /// The Mac answered on the current link.
        case live
    }

    /// The link to this Mac, as far as its data is concerned.
    public enum Link: Equatable, Sendable {
        /// Not being dialed (another Mac is the link's target, or none yet).
        case idle
        case connecting
        /// The last dial or link failed; a retry may be under way.
        case failed(String)
        /// Presence says the Mac is offline.
        case offline
    }

    public enum Event: Equatable, Sendable {
        /// The snapshot restored `count` workspaces saved at `savedAt`.
        case restored(count: Int, savedAt: Date)
        /// A dial to this Mac started.
        case connecting
        /// The Mac answered with its workspace list.
        case received(count: Int)
        case failed(String)
        case offline
        /// The link dropped, or the link moved to another Mac: the list on
        /// screen is now last-known data.
        case disconnected(at: Date)
    }

    /// What the screens show.
    public enum Phase: Equatable, Sendable {
        /// Dialing with nothing to show yet: skeleton rows.
        case loading
        /// Last-known workspaces, dimmed, while `link` says why they are not live.
        case cached(Link)
        /// The Mac's own list, with at least one workspace.
        case live
        /// The Mac answered: it has no workspaces.
        case empty
        /// No data, and the last dial failed.
        case failed(String)
        /// No data, and the Mac is offline.
        case offline
        /// No data, and nothing is dialing this Mac.
        case idle

        /// True only when the Mac itself said it has no workspaces.
        public var isEmpty: Bool { self == .empty }
        /// Rows on screen are not the Mac's live list.
        public var isStale: Bool {
            if case .cached = self { return true }
            return false
        }
        /// Nothing to show yet, but a dial is under way.
        public var isLoading: Bool { self == .loading }
    }

    public private(set) var source: Source = .none
    public private(set) var link: Link = .idle
    public private(set) var count = 0
    private var lastFailure: String?

    public init() {}

    public mutating func handle(_ event: Event) {
        switch event {
        case .restored(let count, let savedAt):
            guard source != .live else { return }
            source = .cache(savedAt: savedAt)
            self.count = count
        case .connecting:
            // A retry keeps showing why the last attempt failed.
            link = lastFailure.map(Link.failed) ?? .connecting
        case .received(let count):
            source = .live
            self.count = count
            link = .idle
            lastFailure = nil
        case .failed(let reason):
            lastFailure = reason
            link = .failed(reason)
        case .offline:
            if source == .live { source = .cache(savedAt: Date()) }
            link = .offline
            lastFailure = nil
        case .disconnected(let at):
            if source == .live { source = .cache(savedAt: at) }
            link = .idle
        }
    }

    public var phase: Phase {
        switch source {
        case .live: count == 0 ? .empty : .live
        case .cache: .cached(link)
        case .none:
            switch link {
            case .idle: .idle
            case .connecting: .loading
            case .failed(let reason): .failed(reason)
            case .offline: .offline
            }
        }
    }
}

extension AppStore {
    /// The data phase of `macID`'s workspaces. Mock mode (and any store that
    /// does not track live data) treats every list as live.
    public func macDataPhase(_ macID: String) -> MacDataMachine.Phase {
        guard tracksMacData else {
            return workspaces.contains { $0.macID == macID } ? .live : .empty
        }
        return macData[macID]?.phase ?? .idle
    }

    public func handleMacData(_ event: MacDataMachine.Event, macID: String) {
        var machine = macData[macID] ?? MacDataMachine()
        machine.handle(event)
        if macData[macID] != machine { macData[macID] = machine }
    }
}

/// What the phone last saw from the live service for one account: the space
/// it used, that space's Macs, the Mac it linked to, and each Mac's
/// workspaces. Restored at launch so the screens show last-known data
/// (marked cached) and the link can dial before the service is asked anything.
public struct LiveSnapshot: Codable, Equatable, Sendable {
    public var teamID: String
    public var teamName: String
    public var macs: [MacDevice]
    /// The Mac the link last reached.
    public var linkedMacID: String?
    /// Mac id → its workspaces when it last answered, and when that was.
    public var workspaces: [String: MacWorkspaces]

    public struct MacWorkspaces: Codable, Equatable, Sendable {
        public var workspaces: [Workspace]
        public var savedAt: Date

        public init(workspaces: [Workspace], savedAt: Date) {
            self.workspaces = workspaces
            self.savedAt = savedAt
        }
    }

    public init(teamID: String, teamName: String, macs: [MacDevice], linkedMacID: String?, workspaces: [String: MacWorkspaces]) {
        self.teamID = teamID
        self.teamName = teamName
        self.macs = macs
        self.linkedMacID = linkedMacID
        self.workspaces = workspaces
    }
}

/// Snapshots on disk, one file per account in Application Support, written
/// off the main thread. Sign-out removes them all.
public final class LiveSnapshotStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "dev.cmux.mobile.snapshot", qos: .utility)

    public init(directory: URL) {
        self.directory = directory
    }

    public static let standard: LiveSnapshotStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LiveSnapshotStore(directory: base.appending(path: "cmux-mobile-live", directoryHint: .isDirectory))
    }()

    private func file(_ accountID: String) -> URL {
        let safe = accountID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appending(path: "snapshot-\(safe).json")
    }

    public func load(accountID: String) -> LiveSnapshot? {
        guard let data = try? Data(contentsOf: file(accountID)) else { return nil }
        return try? JSONDecoder().decode(LiveSnapshot.self, from: data)
    }

    public func save(_ snapshot: LiveSnapshot, accountID: String) {
        let url = file(accountID)
        let directory = directory
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
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

/// This phone's connection to a Mac, apart from the Mac's presence: a Mac
/// can be online (its mobile host holds the service socket) while this phone
/// cannot reach it.
public enum MacConnection: Equatable, Sendable {
    case connecting
    case connected
    /// The last dial failed; the reason is display-safe.
    case failed(String)
}

/// The dot and words next to a Mac's name. Green means this phone is
/// connected (live) or, in mock mode, that the Mac is online; presence
/// alone never makes it green in live mode.
public struct MacStatusLine: Equatable, Sendable {
    public enum Dot: Equatable, Sendable { case connected, connecting, failed, offline }
    public var dot: Dot
    public var text: String

    public init(dot: Dot, text: String) {
        self.dot = dot
        self.text = text
    }

    /// `presence` is the offline wording ("Last seen 2h ago") for an offline Mac.
    public static func make(mac: MacDevice, connection: MacConnection?, live: Bool, presence: String) -> MacStatusLine {
        guard mac.isOnline else { return MacStatusLine(dot: .offline, text: presence) }
        guard live else { return MacStatusLine(dot: .connected, text: presence) }
        switch connection {
        case .connected: return MacStatusLine(dot: .connected, text: "Online")
        case .connecting: return MacStatusLine(dot: .connecting, text: "Online · Connecting…")
        case .failed: return MacStatusLine(dot: .failed, text: "Online · Can't connect")
        case nil: return MacStatusLine(dot: .connecting, text: "Online · Not connected")
        }
    }
}

extension AppStore {
    public func macStatusLine(_ mac: MacDevice, presence: String) -> MacStatusLine {
        MacStatusLine.make(mac: mac, connection: macConnection[mac.id], live: tracksMacData, presence: presence)
    }
}
