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
    /// Rows shown per page of an unfolded group; Show More adds one.
    public static let pageSize = 10
    /// The longest a lane change waits before the groups show it.
    static let refreshInterval: Duration = .seconds(2)
    private static let expandedKey = "sidebar.remoteMachines.expanded"
    private static let prefix = LayoutItemID.transientPrefix + "remote:"
    private static let machinePrefix = prefix + "machine:"
    private static let morePrefix = prefix + "more:"
    private static let sessionPrefix = prefix + "session:"
    private static let resourcesPrefix = prefix + "resources:"
    private static let olderPrefix = prefix + "older:"
    private static let olderMorePrefix = prefix + "older-more:"
    private static let olderSessionPrefix = prefix + "older-session:"

    /// One chat row: only what it draws, so a lane's new step leaves it equal.
    public struct Chat: Hashable, Sendable {
        public var id: String
        public var title: String
        public var harness: String?
        public var activity: StatusIndicatorState
        /// When it last changed state (orders chats across machines).
        var since: Date = .distantPast
    }

    /// One machine's group.
    public struct Machine: Hashable, Sendable {
        public var peer: String
        /// The daemon's link to it is up (true while the peer list is unknown).
        public var online: Bool
        /// Its live chats, newest first.
        public var chats: [Chat]
        /// Its room from acpmux's last reading (nil: unknown).
        public var resources: AcpmuxPeerList.Resources?
    }

    /// A machine's closed chats read so far (its Older row), newest first.
    public struct Older: Hashable, Sendable {
        public var chats: [AcpmuxSessionPage.Chat] = []
        /// The next page's cursor; nil once the last page is read.
        public var next: String?
        /// A page has been read (so an empty `chats` means none, not unknown).
        public var read = false
    }

    /// What the App reaches: the daemon's peers (nil when it cannot say), a page of a peer's
    /// closed chats (nil when it cannot say), a peer's display name, and opening a chat.
    public struct Host {
        public var peers: @Sendable () async -> [AcpmuxPeerList.Peer]?
        public var older: @Sendable (_ peer: String, _ cursor: String?) async -> AcpmuxSessionPage.Page?
        public var displayName: (_ peer: String) -> String?
        public var open: (_ lane: AgentActivityLane) -> Void

        public init(peers: @escaping @Sendable () async -> [AcpmuxPeerList.Peer]?,
                    older: @escaping @Sendable (String, String?) async -> AcpmuxSessionPage.Page?,
                    displayName: @escaping (String) -> String?, open: @escaping (AgentActivityLane) -> Void) {
            self.peers = peers
            self.older = older
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
    /// The machines whose Older row is open, and what each has read; a fold of the group closes it.
    public internal(set) var olderShown: Set<String> = []
    public internal(set) var older: [String: Older] = [:]
    /// The Older page read in flight per machine (one at a time), cancelled by `stop()`.
    @ObservationIgnored private var olderReads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let lanes: AgentLaneStore
    @ObservationIgnored private var host: Host?
    @ObservationIgnored private var peers: [AcpmuxPeerList.Peer]?
    @ObservationIgnored private var laneWatch: Task<Void, Never>?
    /// The next rebuild after a lane change: one per `refreshInterval` however many changes come.
    @ObservationIgnored private let refresh = DemandTimer(owner: "sidebar.remoteMachines")
    /// The peer list read in flight.
    @ObservationIgnored private var peerRead: Task<Void, Never>?
    /// Bumped by each push (`peerStateChanged`): a read in flight then may answer from before it, so
    /// its answer is dropped and the list read again.
    @ObservationIgnored private var peerPushes = 0

    public init(lanes: AgentLaneStore = .shared) {
        self.lanes = lanes
    }

    /// Starts following the lanes. Nothing runs while no lane changes: a change schedules one
    /// rebuild `refreshInterval` later, and each rebuild asks for the peer list. A peer that drops
    /// or comes back changes lanes too (acpmux marks every row of a dropped peer stale, and a
    /// reconnect sends its list), so its header follows. It ends with `stop()`.
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
        olderReads.values.forEach { $0.cancel() }
        olderReads = [:]
    }

    /// The app's own acpmux pushed peer `peer`'s link state (`AgentTurnStateFeed.peerStateChanged`),
    /// or its watch (re)opened (`peer` nil). A listed peer's header follows at once and a repeat
    /// changes nothing; an unknown peer, an offline for one already down (it may be removed), or a
    /// reopened watch reads the list again (one read at a time, as a rebuild does). Nothing runs
    /// before `bind` or after `stop()`. A read in flight when any push lands (one that changes nothing
    /// shown too: the read may have sampled the link between two pushes) is read again after it.
    public func peerStateChanged(peer: String?, state: String?) {
        guard laneWatch != nil else { return }
        peerPushes += 1
        switch Self.push(peer: peer, state: state, onto: peers) {
        case .same: return
        case .read: askForPeers()
        case .list(let next):
            peers = next
            rebuild()
        }
    }

    /// What one pushed link state does to the listed peers.
    nonisolated enum PeerPush: Equatable {
        /// Nothing: a repeat, or a state of the same colour (only `connected` is up).
        case same
        /// The list with that peer's link moved.
        case list([AcpmuxPeerList.Peer])
        /// Read the list again: an unknown peer, an offline for one already down, or no peer.
        case read
    }

    nonisolated static func push(peer: String?, state: String?, onto peers: [AcpmuxPeerList.Peer]?) -> PeerPush {
        guard let peer, let state, var list = peers, let i = list.firstIndex(where: { $0.name == peer }),
              state != "offline" || list[i].connected else { return .read }
        let connected = state == "connected"
        guard list[i].connected != connected else { return .same }
        let old = list[i]
        list[i] = AcpmuxPeerList.Peer(name: old.name, connected: connected, resources: old.resources, url: old.url)
        return .list(list)
    }

    /// The rows now, every group in order. Read inside an observation scope, so a group, fold or
    /// page change re-yields.
    public func rows() -> [SidebarTransientItem] {
        // A capture shows the first sample machine unfolded until a click folds or unfolds one.
        let shown = SidebarTunables.laneFixture.value && expanded.isEmpty && pages.isEmpty ? ["linux-box"] : expanded
        return Self.rows(machines: machines, expanded: shown, pages: pages, resources: SidebarTunables.remoteMachineResources.value,
                         olderShown: olderShown, older: older, displayName: { [host] in host?.displayName($0) })
    }

    /// Runs a click on one of the rows; false for any other item. A header folds or unfolds its
    /// group, Show More adds a page, Older opens or closes the machine's closed chats (its first
    /// page read once), a chat opens.
    public func activate(_ id: LayoutItemID) -> Bool {
        let raw = id.rawValue
        if let peer = Self.suffix(raw, Self.machinePrefix) {
            if expanded.remove(peer) == nil {
                expanded.insert(peer)
            } else {
                // A read in flight would land its page on the fresh state of the next unfold.
                olderReads.removeValue(forKey: peer)?.cancel()
                (pages[peer], older[peer]) = (nil, nil)
                olderShown.remove(peer)
            }
            return true
        }
        if let peer = Self.suffix(raw, Self.olderPrefix) {
            if olderShown.remove(peer) == nil {
                olderShown.insert(peer)
                if older[peer]?.read != true { readOlder(peer, cursor: nil) }
            }
            return true
        }
        if let peer = Self.suffix(raw, Self.olderMorePrefix) {
            if let next = older[peer]?.next { readOlder(peer, cursor: next) }
            return true
        }
        if let rest = Self.suffix(raw, Self.olderSessionPrefix), let cut = rest.firstIndex(of: "/") {
            let (peer, session) = (String(rest[..<cut]), String(rest[rest.index(after: cut)...]))
            let title = older[peer]?.chats.first { $0.id == session }?.title ?? session
            host?.open(AgentActivityLane(id: session, name: peer + "/" + session, title: title, peer: peer, parent: nil, state: .idle,
                                         since: nil, error: nil))
            return true
        }
        if Self.suffix(raw, Self.resourcesPrefix) != nil { return true }
        if let peer = Self.suffix(raw, Self.morePrefix) {
            pages[peer, default: 1] += 1
            return true
        }
        guard let session = Self.suffix(raw, Self.sessionPrefix) else { return false }
        if let lane = lanes.lanes[session] { host?.open(lane) }
        return true
    }

    private func rebuild() {
        guard laneWatch != nil else { return } // stopped: a fire queued before `stop()` does nothing
        askForPeers()
        // Captures run no peers: the sample machines stand in (`sidebar.laneFixture`, Debug, off).
        let next = SidebarTunables.laneFixture.value ? Self.machines(lanes: Self.fixtureLanes, peers: Self.fixturePeers)
            : Self.machines(lanes: lanes.lanes.values, peers: peers)
        if machines != next { machines = next }
    }

    /// One bounded page of `peer`'s closed chats after `cursor`, appended; one read per machine at
    /// a time. A failed read leaves what was read, so the next click tries again.
    private func readOlder(_ peer: String, cursor: String?) {
        guard olderReads[peer] == nil, let read = host?.older else { return }
        // task-owner: this instance; one page read, bounded by the host's 2 s deadline, cancelled by `stop()`
        olderReads[peer] = Task { [weak self] in
            let page = await read(peer, cursor)
            guard let self, !Task.isCancelled else { return }
            olderReads[peer] = nil
            guard olderShown.contains(peer) else { return }
            guard let page else {
                // A first page that failed closes the row again, so the next click reads it anew.
                if older[peer]?.read != true { olderShown.remove(peer) }
                return
            }
            var next = older[peer] ?? Older()
            next.chats += page.chats.filter { chat in !next.chats.contains { $0.id == chat.id } }
            (next.next, next.read) = (page.next, true)
            older[peer] = next
        }
    }

    /// Three machines for captures: two reachable with chats in each state, one offline.
    static let fixturePeers = [
        AcpmuxPeerList.Peer(name: "linux-box", connected: true,
                            resources: .init(ramFreeGB: 31, coresBusy: 12, cores: 32, diskFreeGB: 180, over: false)),
        AcpmuxPeerList.Peer(name: "build-mac", connected: true,
                            resources: .init(ramFreeGB: 2, coresBusy: 12, cores: 12, diskFreeGB: 40, over: true)),
        AcpmuxPeerList.Peer(name: "gpu-box", connected: false),
    ]
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

    /// One bounded `_acpmux/peers` (the daemon answers from memory, never asking a peer),
    /// unless a read is in flight; a changed answer arms `refresh`. An answer a pushed change
    /// overtook (`peerPushes` moved while it was in flight) is dropped and the list read again.
    private func askForPeers() {
        guard peerRead == nil, let read = host?.peers else { return }
        let pushes = peerPushes
        // task-owner: this instance; one read at a time, each bounded by its 2 s deadline, cancelled by `stop()`;
        // a follow-up only when a push came during it (pushes come only on a state change, so a burst ends)
        peerRead = Task { [weak self] in
            let next = await read()
            guard let self, !Task.isCancelled else { return }
            peerRead = nil
            guard pushes == peerPushes else { return askForPeers() }
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
        let room = Dictionary((peers ?? []).map { ($0.name, $0.resources) }, uniquingKeysWith: { first, _ in first })
        let names = peers.map { $0.map(\.name) } ?? Array(byPeer.keys)
        return Set(names).map { peer in
            let isOnline = online[peer] ?? true
            let chats = isOnline ? (byPeer[peer] ?? []).sorted(by: newer).map(chat) : []
            return Machine(peer: peer, online: isOnline, chats: chats, resources: isOnline ? room[peer] ?? nil : nil)
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
        return Chat(id: lane.id, title: title, harness: lane.harness, activity: SidebarTransientItem.activity(of: lane.state),
                    since: lane.since ?? lane.createdAt ?? .distantPast)
    }

    /// The group's indicator: waiting on you over working over idle.
    static func activity(_ chats: [Chat]) -> StatusIndicatorState {
        if chats.contains(where: { $0.activity == .waiting }) { return .waiting }
        if chats.contains(where: { $0.activity == .working }) { return .working }
        return .idle
    }

    @MainActor
    static func rows(machines: [Machine], expanded: Set<String>, pages: [String: Int],
                     resources style: RemoteMachineResourcesStyle = .row, olderShown: Set<String> = [], older: [String: Older] = [:],
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
            let room = machine.online ? machine.resources : nil
            let title = if let room, style == .header { RemoteMachinesStrings.named(name, RemoteMachinesStrings.ramFree(room.ramFreeGB)) }
                else { name }
            var header = SidebarItemInfo(title: machine.online ? title : RemoteMachinesStrings.offline(name), symbol: "cloud", icon: .cloud,
                                         badge: machine.online && !machine.chats.isEmpty ? machine.chats.count : nil, isMissing: !machine.online)
            header.activity = activity(machine.chats)
            add(machinePrefix + machine.peer, header)
            guard machine.online, expanded.contains(machine.peer) else { continue }
            if let room, style == .row {
                var row = SidebarItemInfo(title: RemoteMachinesStrings.resources(room), symbol: "gauge.with.dots.needle.33percent")
                row.indent = 1
                row.accessibilityTitle = RemoteMachinesStrings.resourcesLabel(name, room)
                add(resourcesPrefix + machine.peer, row)
            }
            let shown = pageSize * max(1, pages[machine.peer] ?? 1)
            for chat in machine.chats.prefix(shown) {
                var row = SidebarItemInfo(title: chat.title, symbol: "bubble.left", brand: SidebarItemInfo.agentBrand(forHarness: chat.harness))
                row.agentColor = SidebarItemInfo.stableAgentColor(for: chat.id)
                row.activity = chat.activity
                row.indent = 1
                add(sessionPrefix + chat.id, row)
            }
            if machine.chats.count > shown {
                var more = SidebarItemInfo(title: RemoteMachinesStrings.showMore, symbol: "ellipsis")
                more.indent = 1
                add(morePrefix + machine.peer, more)
            }
            // Its closed chats, behind one row: never counted, read a page at a time when opened.
            var olderRow = SidebarItemInfo(title: RemoteMachinesStrings.older, symbol: "clock.arrow.circlepath")
            olderRow.indent = 1
            add(olderPrefix + machine.peer, olderRow)
            guard olderShown.contains(machine.peer), let read = older[machine.peer] else { continue }
            for chat in read.chats {
                var row = SidebarItemInfo(title: chat.title, symbol: "bubble.left", isMissing: true,
                                          brand: SidebarItemInfo.agentBrand(forHarness: chat.harness))
                row.agentColor = SidebarItemInfo.stableAgentColor(for: chat.id)
                row.indent = 2
                add(olderSessionPrefix + machine.peer + "/" + chat.id, row)
            }
            if read.next != nil {
                var more = SidebarItemInfo(title: RemoteMachinesStrings.showMore, symbol: "ellipsis")
                more.indent = 2
                add(olderMorePrefix + machine.peer, more)
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
    /// A machine's room on one line that fits the sidebar: "31 GB free · CPU 12/32", led by "Busy"
    /// when its own budget says it is over, and ending with its free disk only when that is low.
    /// "CPU n/m" names no counted noun, so it reads right for any count.
    static func resources(_ r: AcpmuxPeerList.Resources) -> String {
        var parts = [ramFree(r.ramFreeGB),
                     String(format: String(localized: "sidebar.remoteMachines.cpu", defaultValue: "CPU %1$lld/%2$lld", bundle: .module),
                            r.coresBusy, r.cores)]
        if let disk = r.diskFreeGB, disk < lowDiskGB {
            parts.append(String(format: String(localized: "sidebar.remoteMachines.disk", defaultValue: "%lld GB disk", bundle: .module), disk))
        }
        if r.over { parts.insert(String(localized: "sidebar.remoteMachines.overBudget", defaultValue: "Busy", bundle: .module), at: 0) }
        return parts.joined(separator: " · ")
    }
    /// What VoiceOver reads for a machine's room row: the machine, then its room.
    static func resourcesLabel(_ name: String, _ r: AcpmuxPeerList.Resources) -> String {
        String(format: String(localized: "sidebar.remoteMachines.resourcesLabel", defaultValue: "%1$@: %2$@", bundle: .module),
               name, resources(r))
    }
    /// Free disk under this many GB shows on the row (lane hosts' usual floor in fleet-registry.json).
    static let lowDiskGB = 20
    static func ramFree(_ gb: Int) -> String {
        String(format: String(localized: "sidebar.remoteMachines.ramFree", defaultValue: "%lld GB free", bundle: .module), gb)
    }
    /// A header with something after the machine's name.
    static func named(_ name: String, _ detail: String) -> String { name + " · " + detail }
    /// The row under an unfolded group's live chats that opens its closed ones.
    static var older: String { String(localized: "sidebar.remoteMachines.older", defaultValue: "Older", bundle: .module) }
    /// The row under an unfolded group's last shown chat when it has more.
    static var showMore: String { String(localized: "sidebar.remoteMachines.showMore", defaultValue: "Show More", bundle: .module) }
}
