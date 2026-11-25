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
