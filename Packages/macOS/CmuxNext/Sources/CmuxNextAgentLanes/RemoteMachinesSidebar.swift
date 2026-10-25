public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextIcons
import CmuxNextWakeups
public import CmuxNextSidebar
import Foundation
public import Observation

/// The agent chats running on other machines, in the sidebar (Leo 2026-10-24: "it should just be
/// able to show me, say on my sidebar, right? Like we already discussed this, like with the cloud
/// icon, the group where, you know, on a different machine or whatever, there's the other agent
/// sessions"). One group per acpmux peer this Mac's daemon mirrors (huge-blue, big-red, cmux16…):
/// a header row with the cloud icon, the machine's name and its live chats' count, folded by
/// default; unfolded, its live chats newest first, a page at a time. A click on a chat opens its
/// chat in a tab (the Priority view's path), never a terminal and never a new workspace. A peer
/// the daemon cannot reach shows as offline, with no rows.
///
/// Peers hold hundreds of chats and their agents change lanes many times a second, so the rows
/// never follow an event: a lane change marks the groups stale, and they are rebuilt at most once
/// per `refreshInterval`, from the lanes' states and titles only (a new step changes nothing).
@Observable @MainActor
public final class RemoteMachinesSidebar {
    public static let shared = RemoteMachinesSidebar()
    /// Rows shown per page of an unfolded group; Show More adds one.
    static let pageSize = 10
    /// The longest a lane change waits before the groups show it.
    static let refreshInterval: Duration = .seconds(2)
    /// How often the daemon's peer list (who is reachable) is read again.
    static let peerInterval: Duration = .seconds(20)
    private static let expandedKey = "sidebar.remoteMachines.expanded"
    private static let prefix = LayoutItemID.transientPrefix + "remote:"
    private static let machinePrefix = prefix + "machine:"
    private static let morePrefix = prefix + "more:"
    private static let sessionPrefix = prefix + "session:"

    /// One chat row: only what it draws, so a lane's new step leaves it equal.
    public struct Chat: Hashable, Sendable {
        public var id: String
        public var title: String
        public var harness: String?
        public var activity: StatusIndicatorState
    }

    /// One machine's group.
    public struct Machine: Hashable, Sendable {
        public var peer: String
        /// The daemon's link to it is up (true while the peer list is unknown).
        public var online: Bool
        /// Its live chats, newest first.
        public var chats: [Chat]
    }

    /// What the App reaches: the daemon's peers (nil when it cannot say), a peer's display name,
    /// and opening a chat.
    public struct Host {
        public var peers: @Sendable () async -> [AcpmuxPeerList.Peer]?
        public var displayName: (_ peer: String) -> String?
        public var open: (_ lane: AgentActivityLane) -> Void

        public init(peers: @escaping @Sendable () async -> [AcpmuxPeerList.Peer]?, displayName: @escaping (String) -> String?,
                    open: @escaping (AgentActivityLane) -> Void) {
            self.peers = peers
            self.displayName = displayName
            self.open = open
        }
    }

    /// The groups, by machine name. Written only when they change.
    public internal(set) var machines: [Machine] = []
    /// The unfolded machines (folded by default). This view state stays on this Mac.
    public var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: RemoteMachinesSidebar.expandedKey) ?? []) {
        didSet { UserDefaults.standard.set(expanded.sorted(), forKey: Self.expandedKey) }
    }
    /// Pages an unfolded group shows (1 when absent); a fold resets it.
    public internal(set) var pages: [String: Int] = [:]
    @ObservationIgnored private let lanes: AgentLaneStore
    @ObservationIgnored private var host: Host?
    @ObservationIgnored private var peers: [AcpmuxPeerList.Peer]?
    @ObservationIgnored private var laneWatch: Task<Void, Never>?
    /// The next rebuild after a lane change: one per `refreshInterval` however many changes come.
    @ObservationIgnored private let refresh = DemandTimer(owner: "sidebar.remoteMachines")
    /// When the peer list was last asked for, and the read in flight.
    @ObservationIgnored private var peersAskedAt: ContinuousClock.Instant?
    @ObservationIgnored private var peerRead: Task<Void, Never>?

    public init(lanes: AgentLaneStore = .shared) {
        self.lanes = lanes
    }

    /// Starts following the lanes. Nothing runs while no lane changes: a change schedules one
    /// rebuild `refreshInterval` later, and a rebuild asks for the peer list when it is older than
    /// `peerInterval`. It ends with `stop()`.
    public func bind(host: Host) {
        self.host = host
        guard laneWatch == nil else { return }
        let lanes = lanes, refresh = refresh
        // task-owner: this instance; event-driven (Observation); each change only arms the one-shot `refresh`
        laneWatch = Task { [weak self] in
            for await _ in ObservationStream({ _ = lanes.lanes; _ = SidebarTunables.laneFixture.value }) {
                refresh.scheduleIfIdle(after: Self.refreshInterval) { @MainActor [weak self] in self?.rebuild() }
            }
        }
        rebuild()
    }

    public func stop() {
        laneWatch?.cancel()
        refresh.cancel()
        peerRead?.cancel()
        (laneWatch, peerRead) = (nil, nil)
    }

    /// The rows now, every group in order. Read inside an observation scope, so a group, fold or
    /// page change re-yields.
    public func rows() -> [SidebarTransientItem] {
        // A capture shows the first sample machine unfolded until a click folds or unfolds one.
        let shown = SidebarTunables.laneFixture.value && expanded.isEmpty && pages.isEmpty ? ["linux-box"] : expanded
        return Self.rows(machines: machines, expanded: shown, pages: pages, displayName: { [host] in host?.displayName($0) })
    }

    /// Runs a click on one of the rows; false for any other item. A header folds or unfolds its
    /// group, Show More adds a page, a chat opens.
    public func activate(_ id: LayoutItemID) -> Bool {
        let raw = id.rawValue
        if let peer = Self.suffix(raw, Self.machinePrefix) {
            if expanded.remove(peer) == nil { expanded.insert(peer) } else { pages[peer] = nil }
            return true
        }
        if let peer = Self.suffix(raw, Self.morePrefix) {
            pages[peer, default: 1] += 1
            return true
        }
        guard let session = Self.suffix(raw, Self.sessionPrefix) else { return false }
        if let lane = lanes.lanes[session] { host?.open(lane) }
        return true
    }

    private func rebuild() {
        askForPeersIfStale()
        // Captures run no peers: the sample machines stand in (`sidebar.laneFixture`, Debug, off).
        let next = SidebarTunables.laneFixture.value ? Self.machines(lanes: Self.fixtureLanes, peers: Self.fixturePeers)
            : Self.machines(lanes: lanes.lanes.values, peers: peers)
        if machines != next { machines = next }
    }

    /// Three machines for captures: two reachable with chats in each state, one offline.
    static let fixturePeers = [AcpmuxPeerList.Peer(name: "linux-box", connected: true), AcpmuxPeerList.Peer(name: "build-mac", connected: true),
                               AcpmuxPeerList.Peer(name: "gpu-box", connected: false)]
    static var fixtureLanes: [AgentActivityLane] {
        let chats: [(String, String, AgentActivityLane.State, String)] = [
            ("linux-box", "sidebar", .working, "Sidebar rows keep their place"), ("linux-box", "review-1", .input, "Review the peer list"),
            ("linux-box", "review-2", .idle, "Land the composer fix"), ("build-mac", "cache", .working, "Prune DerivedData on the minis"),
            ("build-mac", "nightly", .idle, "Nightly 1.0.312 published"),
        ]
        return chats.enumerated().map { i, chat in
            AgentActivityLane(id: "fixture-remote:\(chat.0)/\(chat.1)", name: "\(chat.0)/\(chat.1)", title: chat.3, peer: chat.0, parent: nil,
                              state: chat.2, since: Date(timeIntervalSince1970: TimeInterval(1_000 - i)), error: nil,
                              harness: i.isMultiple(of: 2) ? "claude" : "codex")
        }
    }

    /// One bounded `_acpmux/peers` (the daemon answers from memory, never asking a peer) when the
    /// list is older than `peerInterval` and no read is in flight; a changed answer arms `refresh`.
    private func askForPeersIfStale() {
        guard peerRead == nil, let read = host?.peers else { return }
        let now = ContinuousClock.now
        if let asked = peersAskedAt, now - asked < Self.peerInterval { return }
        peersAskedAt = now
        // task-owner: this instance; one read, bounded by its 2 s deadline, cancelled by `stop()`
        peerRead = Task { [weak self] in
            let next = await read()
            guard let self, !Task.isCancelled else { return }
            peerRead = nil
            if next != peers {
                peers = next
                // Through the same gate as a lane change: still one rebuild per refreshInterval.
                refresh.scheduleIfIdle(after: Self.refreshInterval) { @MainActor [weak self] in self?.rebuild() }
            }
        }
    }

    // MARK: - Model

    /// The groups: every peer the daemon lists (none listed yet: every peer a lane names), each
    /// with its live chats newest first, reachable machines first. A peer the daemon cannot reach has no chats.
    static func machines(lanes: some Collection<AgentActivityLane>, peers: [AcpmuxPeerList.Peer]?) -> [Machine] {
        var byPeer: [String: [AgentActivityLane]] = [:]
        for lane in lanes {
            guard let peer = lane.peer else { continue }
            byPeer[peer, default: []].append(lane)
        }
        let online = Dictionary((peers ?? []).map { ($0.name, $0.connected) }, uniquingKeysWith: { first, _ in first })
        let names = peers.map { $0.map(\.name) } ?? Array(byPeer.keys)
        return Set(names).map { peer in
            let isOnline = online[peer] ?? true
            let chats = isOnline ? (byPeer[peer] ?? []).sorted(by: newer).map(chat) : []
            return Machine(peer: peer, online: isOnline, chats: chats)
        }
        // Reachable machines first, each part by name.
        .sorted { ($0.online ? 0 : 1, $0.peer) < ($1.online ? 0 : 1, $1.peer) }
    }

    /// Newest first by when it last changed state (a step leaves the order alone), then by name.
    static func newer(_ a: AgentActivityLane, _ b: AgentActivityLane) -> Bool {
        let (x, y) = (a.since ?? a.createdAt ?? .distantPast, b.since ?? b.createdAt ?? .distantPast)
        return x != y ? x > y : a.name < b.name
    }

    static func chat(_ lane: AgentActivityLane) -> Chat {
        let title = lane.title == lane.name ? String(lane.name.split(separator: "/").last ?? Substring(lane.name)) : lane.title
        return Chat(id: lane.id, title: title, harness: lane.harness, activity: SidebarTransientItem.activity(of: lane.state))
    }

    /// The group's indicator: waiting on you over working over idle.
    static func activity(_ chats: [Chat]) -> StatusIndicatorState {
        if chats.contains(where: { $0.activity == .waiting }) { return .waiting }
        if chats.contains(where: { $0.activity == .working }) { return .working }
        return .idle
    }

    @MainActor
    static func rows(machines: [Machine], expanded: Set<String>, pages: [String: Int],
                     displayName: (String) -> String?) -> [SidebarTransientItem] {
        var items: [SidebarTransientItem] = []
        // The groups draw right after the top items (the App Store, else Channels, else Home), above the workspaces.
        var previous: [LayoutItemRef] = [.app("cmux/app-store"), SidebarTransientItem.channels.item.ref, SidebarLayoutDocument.homeRef,
                                         .builtIn(.home)]
        func add(_ id: String, _ info: SidebarItemInfo) {
            let item = SidebarTransientItem(id: LayoutItemID(id), info: info, after: previous)
            previous = [item.item.ref]
            items.append(item)
        }
        for machine in machines {
            let name = displayName(machine.peer) ?? machine.peer
            var header = SidebarItemInfo(title: machine.online ? name : RemoteMachinesStrings.offline(name), symbol: "cloud", icon: .cloud,
                                         badge: machine.online && !machine.chats.isEmpty ? machine.chats.count : nil, isMissing: !machine.online)
            header.activity = activity(machine.chats)
            add(machinePrefix + machine.peer, header)
            guard machine.online, expanded.contains(machine.peer) else { continue }
            let shown = pageSize * max(1, pages[machine.peer] ?? 1)
            for chat in machine.chats.prefix(shown) {
                var row = SidebarItemInfo(title: chat.title, symbol: "bubble.left", brand: chat.harness)
                row.activity = chat.activity
                row.indent = 1
                add(sessionPrefix + chat.id, row)
            }
            if machine.chats.count > shown {
                var more = SidebarItemInfo(title: RemoteMachinesStrings.showMore, symbol: "ellipsis")
                more.indent = 1
                add(morePrefix + machine.peer, more)
            }
        }
        return items
    }

    private static func suffix(_ raw: String, _ prefix: String) -> String? {
        raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : nil
    }
}

enum RemoteMachinesStrings {
    /// A machine's group header while this Mac's acpmux cannot reach it.
    static func offline(_ name: String) -> String {
        String(format: String(localized: "sidebar.remoteMachines.offline", defaultValue: "%@ · Offline", bundle: .module), name)
    }
    /// The row under an unfolded group's last shown chat when it has more.
    static var showMore: String { String(localized: "sidebar.remoteMachines.showMore", defaultValue: "Show More", bundle: .module) }
}
