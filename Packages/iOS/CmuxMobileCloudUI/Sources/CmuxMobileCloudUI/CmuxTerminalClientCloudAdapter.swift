#if os(iOS)
public import CmuxMobileCloud
public import Foundation
internal import CmuxTerminalClientKit
internal import CmuxTerminalClientModel

/// Bridges the prebuilt Rust client (`CmuxTerminalClientKit`) to the Cloud
/// domain's transport seams, so `CmuxMobileCloud` stays free of the binary.
///
/// The composition root builds one of these and injects it into
/// ``CloudSessionController``.
public struct CmuxTerminalClientCloudTunnelStarter: CloudTunnelStarting {
    /// Creates a starter.
    public init() {}

    public func start(wgQuickConfig: String) async throws -> any CloudTunnel {
        // The FFI parses the config and brings the tunnel up synchronously;
        // run it off the cooperative pool so the actor hop does not block.
        try await Task.detached(priority: .userInitiated) {
            KitTunnel(net: try WireGuardNet(wgQuickConfig: wgQuickConfig))
        }.value
    }
}

/// Opens daemon links with `CmuxTerminalClientKit`, dialing through the shared
/// tunnel when one is supplied.
public struct CmuxTerminalClientCloudConnector: CloudTerminalConnecting {
    /// Creates a connector.
    public init() {}

    public func connect(
        route: String,
        stateDirectory: URL,
        deviceName: String,
        invitation: String?,
        trustedCarrier: Bool,
        tunnel: (any CloudTunnel)?
    ) async throws -> any CloudTerminalSession {
        let net = (tunnel as? KitTunnel)?.net
        return try await Task.detached(priority: .userInitiated) {
            let client = try TerminalClient.connect(
                route: route,
                stateDirectory: stateDirectory,
                deviceName: deviceName,
                invitation: invitation,
                trustedCarrier: trustedCarrier,
                wireGuard: net
            )
            // The phone's grid wins when a Mac shares the terminal: the
            // product rule for Cloud, since the phone has the smaller screen
            // and a shared minimum would fit neither.
            client.setViewerSizePriority(true)
            return KitSession(client: client)
        }.value
    }
}

/// A tunnel that owns a `CmuxTerminalClientKit.WireGuardNet`.
final class KitTunnel: CloudTunnel {
    let net: WireGuardNet
    init(net: WireGuardNet) { self.net = net }
}

/// A session over a `CmuxTerminalClientKit.TerminalClient`.
final class KitSession: CloudTerminalSession, @unchecked Sendable {
    private let client: TerminalClient

    init(client: TerminalClient) { self.client = client }

    func listWorkspaces() async throws -> [CloudWorkspaceSummary] {
        try client.listWorkspaces().map { CloudWorkspaceSummary(id: $0.id, name: $0.name, root: $0.root) }
    }

    func createWorkspace(name: String?) async throws -> String {
        try client.createWorkspace(name: name)
    }

    func loadCatalog() async throws -> (workspaces: [CloudWorkspaceSummary], terminals: [CloudTerminalSummary]) {
        let catalog: SessionCatalog
        do {
            catalog = try client.loadCatalog()
        } catch {
            // A daemon that cannot answer the snapshot still answers the
            // lists; its terminals just cannot be placed in workspaces.
            async let workspaces = listWorkspaces()
            async let terminals = listTerminals()
            return try await (workspaces, terminals)
        }
        return (
            catalog.workspaces.map { CloudWorkspaceSummary(id: $0.id, name: $0.name, root: $0.root) },
            catalog.terminals.map {
                CloudTerminalSummary(
                    id: $0.id,
                    name: $0.name,
                    workspaceID: $0.workspaceID,
                    title: $0.title,
                    currentDirectory: $0.cwd
                )
            }
        )
    }

    func listTerminals() async throws -> [CloudTerminalSummary] {
        try client.listTerminals().map {
            CloudTerminalSummary(
                id: $0.id,
                name: $0.name,
                workspaceID: $0.workspaceID,
                title: $0.title,
                currentDirectory: $0.cwd
            )
        }
    }

    func createTerminal(name: String?) async throws -> String {
        try client.createTerminal(name: name)
    }

    func createTerminal(inWorkspace workspaceID: String, name: String?) async throws -> String {
        try client.createTerminal(inWorkspace: workspaceID, name: name)
    }

    func attach(terminalID: String, output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void) async throws {
        client.setOutputHandler { event in
            output(Self.map(event))
        }
        try client.attach(terminalID: terminalID)
    }

    func detach() { client.detach() }
    func send(_ bytes: Data) { _ = client.send(bytes) }
    func resize(cols: Int, rows: Int) {
        _ = client.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }
    func disconnect() {
        client.disconnect()
    }

    private static func map(_ event: TerminalOutputEvent) -> CloudTerminalOutputEvent {
        switch event {
        case .snapshot(let replay, let cols, let rows):
            return .snapshot(replay: replay, cols: Int(cols), rows: Int(rows))
        case .output(let data):
            return .output(data)
        case .resized(let cols, let rows):
            return .resized(cols: Int(cols), rows: Int(rows))
        case .exited:
            return .exited
        }
    }
}
#endif
