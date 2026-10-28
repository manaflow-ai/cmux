import CmuxNextAgentPane

/// The sources consumed by EnvironmentPicker: acpmux's status peers and cloudMachine.list.
/// A peer wins over an account machine with the same name, including its actual link state.
struct AgentChatDestinations {
    struct Destination: Equatable {
        enum Route: Equatable { case local, peer(String), cloud(String) }
        let id: String
        let title: String
        let state: String?
        let symbol: String
        let isReady: Bool
        let route: Route
    }

    var peers: () async throws -> [AgentChatPeer]
    var cloud: () async -> AgentPaneCloudMachines.Inventory

    init(peers: @escaping () async throws -> [AgentChatPeer], cloud: @escaping () async -> AgentPaneCloudMachines.Inventory) {
        (self.peers, self.cloud) = (peers, cloud)
    }

    init(services: AppServices) {
        let host = services.agentTabs.host
        peers = { try await host.chatPeers() }
        cloud = { await AgentPaneCloudMachines.shared.list?() ?? .init(signedIn: false, loaded: false, machines: []) }
    }

    static var local: Destination {
        .init(id: MachineRegistry.localID, title: WorkspaceVerbStrings.thisMac, state: nil,
              symbol: "laptopcomputer", isReady: true, route: .local)
    }

    func load() async -> [Destination] {
        let peers = (try? await peers()) ?? []
        let inventory = await cloud()
        return Self.rows(peers: peers, cloud: inventory)
    }

    static func rows(peers: [AgentChatPeer], cloud: AgentPaneCloudMachines.Inventory) -> [Destination] {
        var seen = Set<String>()
        var rows = [local]
        for peer in peers where seen.insert(peer.name).inserted {
            rows.append(.init(id: peer.name, title: peer.name, state: peer.state ?? (peer.connected == false ? "offline" : nil),
                              symbol: peer.isSSH ? "network" : "cloud", isReady: peer.isReady, route: .peer(peer.name)))
        }
        // cloudMachines.ts uses a case-insensitive name match to retain acpmux's live state.
        let peerNames = Set(rows.map { $0.title.lowercased() } + rows.map { $0.id.lowercased() })
        if cloud.signedIn && cloud.loaded {
            for machine in cloud.machines.prefix(200) where !peerNames.contains(machine.name.lowercased()) {
                rows.append(.init(id: "cloud-machine:" + machine.id, title: machine.name, state: machine.stage,
                                  symbol: "cloud", isReady: machine.stage == "ready", route: .cloud(machine.id)))
            }
        }
        return rows
    }

    /// Exact ids take precedence. Names must be unique; an unknown or ambiguous name never
    /// silently falls back to this Mac. CLI may use the Cloud id without the row prefix.
    static func resolve(_ name: String, in rows: [Destination]) -> Destination? {
        if let exact = rows.first(where: { $0.id == name }) { return exact }
        let matches = rows.filter {
            if case .cloud(let id) = $0.route, id == name { return true }
            return $0.title == name
        }
        return matches.count == 1 ? matches.first : nil
    }
}
