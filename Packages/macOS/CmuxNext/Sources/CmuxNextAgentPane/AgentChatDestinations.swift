
/// The sources consumed by EnvironmentPicker: acpmux's status peers and cloudMachine.list.
/// Peers and account machines retain their own identities and availability even when names match.
public struct AgentChatDestinations {
    public struct Destination: Equatable {
        public enum Route: Equatable { case local, peer(String), cloud(String) }
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
