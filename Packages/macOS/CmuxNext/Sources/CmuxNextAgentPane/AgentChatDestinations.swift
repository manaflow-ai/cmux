
/// The sources consumed by EnvironmentPicker: acpmux's status peers and cloudMachine.list.
/// Peers and account machines retain their own identities and availability even when names match.
public struct AgentChatDestinations {
    public struct Destination: Equatable {
        /// `pending`: the picker's notice that this Mac's acpmux has not listed its peers yet; never picked.
        public enum Route: Equatable { case local, peer(String), cloud(String), pending }
        public let id: String
        public let title: String
        public let state: String?
        public let symbol: String
        public let isReady: Bool
        public let route: Route
    }

    private var peers: () async throws -> [AgentChatPeer]
    private var cloud: () async -> AgentPaneCloudMachines.Inventory

    public let local: Destination

    public init(localTitle: String, peers: @escaping () async throws -> [AgentChatPeer], cloud: @escaping () async -> AgentPaneCloudMachines.Inventory) {
        self.local = Self.local(title: localTitle)
        (self.peers, self.cloud) = (peers, cloud)
    }

    public static func local(title: String) -> Destination {
        .init(id: "local", title: title, state: nil, symbol: "laptopcomputer", isReady: true, route: .local)
    }

    /// The id of the row a picker shows while this Mac's acpmux has not listed its peers yet.
    public static let peersPendingID = "peers-pending"

    /// The rows a picker shows, over time (R9 R-L5: a limit that drops data shows the loss). The
    /// picker does not wait for a slow acpmux: past `peerBound` it shows this Mac, the Cloud
    /// machines and a notice that the other Macs are not loaded yet, and when acpmux lists its
    /// peers it shows them (the late reply is not dropped). `peerBound` only decides what is drawn
    /// first; the peers request is never given up (rule R5), only cancelled with the stream.
    public func updates(peerBound: Duration = .seconds(2)) -> AsyncStream<[Destination]> {
        // The newest list is all a picker needs.
        let (stream, continuation) = AsyncStream.makeStream(of: [Destination].self, bufferingPolicy: .bufferingNewest(1))
        let peers = peers
        let cloud = cloud
        let title = local.title
        // task-owner: the peers request; cancelled with the stream's consumer
        let peersTask = Task { try await peers() }
        // task-owner: ends with the stream's consumer (onTermination cancels it)
        let task = Task {
            // task-owner: the Cloud inventory, read at the same time as the peers; cancelled with this task
            let cloudTask = Task { await cloud() }
            let early = await Self.peers(of: peersTask, within: peerBound)
            let inventory = await withTaskCancellationHandler { await cloudTask.value } onCancel: { cloudTask.cancel() }
            guard !Task.isCancelled else { return continuation.finish() }
            if case .late = early {
                continuation.yield(Self.rows(localTitle: title, peers: [], cloud: inventory, notice: Self.peersPending))
            }
            let listed: [AgentChatPeer]?
            switch early {
            case .listed(let peers): listed = peers
            case .failed: listed = nil
            case .late: listed = try? await peersTask.value
            }
            guard !Task.isCancelled else { return continuation.finish() }
            // A peers request that failed is said, never shown as a Mac with no other Macs.
            continuation.yield(Self.rows(localTitle: title, peers: listed ?? [], cloud: inventory,
                                         notice: listed == nil ? Self.peersFailed : nil))
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
            peersTask.cancel()
        }
        return stream
    }

    /// Whether the peers came within the bound.
    private enum EarlyPeers: Sendable {
        case listed([AgentChatPeer])
        case failed
        case late
    }

    /// `task`'s peers when they come within `bound`; `.late` otherwise (the task goes on). The
    /// first of the two ends the wait (one resume), and the bound's sleep is cancelled then.
    private static func peers(of task: Task<[AgentChatPeer], any Error>, within bound: Duration) async -> EarlyPeers {
        let once = AgentPaneResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<EarlyPeers, Never>) in
            // task-owner: the bound; cancelled when the peers come first
            let timer = Task {
                // wakeup-allow: one one-shot bound per picker open; it decides only what is drawn first, never whether the peers request ends
                // A cancelled bound (the peers came first) says nothing.
                guard (try? await Task.sleep(for: bound)) != nil else { return }
                once.run { continuation.resume(returning: .late) }
            }
            // task-owner: reads the peers task's end; ends when it ends
            Task {
                let early: EarlyPeers
                do { early = .listed(try await task.value) } catch { early = .failed }
                timer.cancel()
                once.run { continuation.resume(returning: early) }
            }
        }
    }

    /// The notice row: this Mac's acpmux has not listed the other Macs yet.
    static var peersPending: Destination {
        .init(id: peersPendingID, title: String(localized: "agentPane.chatDestinations.peersPending",
                                                defaultValue: "Other Macs not loaded yet", bundle: .module),
              state: nil, symbol: "hourglass", isReady: false, route: .pending)
    }

    /// The id of the row a picker shows when this Mac's acpmux could not list its peers.
    public static let peersFailedID = "peers-failed"

    /// The notice row: this Mac's acpmux could not list the other Macs (not running, refused).
    static var peersFailed: Destination {
        .init(id: peersFailedID, title: String(localized: "agentPane.chatDestinations.peersFailed",
                                               defaultValue: "Other Macs could not be loaded", bundle: .module),
              state: nil, symbol: "exclamationmark.triangle", isReady: false, route: .pending)
    }

    /// ``rows(localTitle:peers:cloud:)`` with `notice` (if any) after this Mac.
    static func rows(localTitle: String, peers: [AgentChatPeer], cloud: AgentPaneCloudMachines.Inventory,
                     notice: Destination?) -> [Destination] {
        var rows = rows(localTitle: localTitle, peers: peers, cloud: cloud)
        if let notice { rows.insert(notice, at: 1) }
        return rows
    }

    /// The rows that can resolve `wanted`: a Cloud machine named by its row id
    /// (`cloud-machine:<id>`) needs only the Cloud inventory, so it never waits on this Mac's
    /// acpmux; any other name waits for the full list (the caller's cancel ends that wait).
    public func load(for wanted: String) async -> [Destination] {
        guard wanted.hasPrefix("cloud-machine:") else { return await load() }
        return Self.rows(localTitle: local.title, peers: [], cloud: await cloud())
    }

    public func load() async -> [Destination] {
        let peers = (try? await peers()) ?? []
        let inventory = await cloud()
        return Self.rows(localTitle: local.title, peers: peers, cloud: inventory)
    }

    public static func rows(localTitle: String, peers: [AgentChatPeer], cloud: AgentPaneCloudMachines.Inventory) -> [Destination] {
        var seen = Set<String>()
        var rows = [local(title: localTitle)]
        for peer in peers where seen.insert(peer.name).inserted {
            rows.append(.init(id: peer.name, title: peer.name, state: peer.state ?? (peer.connected == false ? "offline" : nil),
                              symbol: peer.isSSH ? "network" : "cloud", isReady: peer.isReady, route: .peer(peer.name)))
        }
        // Keep Cloud identities even when acpmux reports a peer with the same display name:
        // callers can choose the machine's stable id independently of that peer's link state.
        if cloud.signedIn && cloud.loaded {
            for machine in cloud.machines.prefix(200) {
                rows.append(.init(id: "cloud-machine:" + machine.id, title: machine.name, state: machine.stage,
                                  symbol: "cloud", isReady: machine.stage == "ready", route: .cloud(machine.id)))
            }
        }
        return rows
    }

    /// Exact ids take precedence. Names must be unique; an unknown or ambiguous name never
    /// silently falls back to this Mac. CLI may use the Cloud id without the row prefix.
    public static func resolve(_ name: String, in rows: [Destination]) -> Destination? {
        if let exact = rows.first(where: { $0.id == name }) { return exact }
        if let cloud = rows.first(where: {
            if case .cloud(let id) = $0.route { return id == name }
            return false
        }) { return cloud }
        let matches = rows.filter { $0.title == name }
        return matches.count == 1 ? matches.first : nil
    }
}
