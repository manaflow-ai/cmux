public import CmuxMobileHost
public import CmuxNextDaemon
import CmuxMobileWire
import Foundation

/// The app adapter B5 left unwritten (b5-mac-host.md section 6,
/// c1-terminal-rpc.md section 2): `MobileDaemon` over a dedicated
/// `DaemonConnection`, so phone traffic never queues behind the Mac's own
/// tree mirror or runs on the main actor. Terminals attach on their own
/// connections (`TerminalAttachment`), like the Mac's terminal views.
public final class DaemonMobileDaemon: MobileDaemon {
    private let connection: DaemonConnection
    private let projection: MobileTreeProjection
    private let changes = TreeChangeSignal()
    private let pump: Task<Void, Never>

    /// Connects with tree deltas and starts forwarding tree changes.
    public static func connect(hostID: String,
                               endpointProvider: @escaping DaemonConnection.EndpointProvider) async throws -> DaemonMobileDaemon {
        let connection = DaemonConnection(configuration: DaemonConnection.Configuration(clientName: "cmux-next-mobile-link"),
                                          endpointProvider: endpointProvider)
        _ = try await connection.start()
        return DaemonMobileDaemon(connection: connection, projection: MobileTreeProjection(hostID: hostID))
    }

    private init(connection: DaemonConnection, projection: MobileTreeProjection) {
        self.connection = connection
        self.projection = projection
        let events = connection.events
        let changes = changes
        // task-owner: ends when the connection's event stream finishes (close())
        pump = Task.detached {
            do {
                for try await _ in events { await changes.signal() }
            } catch {}
            await changes.finish()
        }
    }

    public func close() async {
        await connection.close()
        await changes.finish()
        pump.cancel()
    }

    public func workspaceState() async throws -> MobileWorkspaceState {
        projection.state(try await tree())
    }

    public func workspaceChanges() async -> AsyncStream<Void> {
        await changes.subscribe()
    }

    public func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult {
        let tree = try await tree()
        switch op {
        case .renameWorkspace(let workspace, let name):
            guard let key = projection.workspaceKey(workspace, in: tree) else {
                throw MobileDaemonError(code: "workspace.not_found", message: "\(workspace) is not on this Mac")
            }
            _ = try await mapped { try await self.connection.renameWorkspace(key, to: name) }
        case .closeTab(let tab):
            guard let surface = projection.surface(ofTab: tab, in: tree) else {
                throw MobileDaemonError(code: "workspace.tab_not_found", message: "\(tab) is not on this Mac")
            }
            try await mapped { try await self.connection.closeTab(surface) }
        case .closeWorkspace(let workspace):
            guard let key = projection.workspaceKey(workspace, in: tree) else {
                throw MobileDaemonError(code: "workspace.not_found", message: "\(workspace) is not on this Mac")
            }
            // Like the phone's tab close, the workspace's terminals end with it.
            _ = try await mapped { try await self.connection.closeWorkspace(key, endTerminals: true) }
        case .markWorkspaceRead:
            // The daemon has no clear-unread command yet; the phone hides Mark
            // as Read when the host answers this.
            throw MobileDaemonError(code: "proto.unsupported", message: "marking a workspace read is not supported by this Mac")
        case .createWorkspace, .createTab:
            // The policy refuses spawning ops until a live verification
            // (b5-mac-host.md section 3); this adapter never spawns.
            throw MobileDaemonError(code: "auth.forbidden", message: "terminal spawn from a phone is not enabled")
        }
        return MobileDaemonOpResult()
    }

    public func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        let tree = try await tree()
        guard let tab = projection.tab(showing: request.terminal, in: tree) else {
            throw MobileDaemonError(code: "terminal.not_found", message: "\(request.terminal) is not on this Mac")
        }
        guard let endpoint = await connection.endpoint else {
            throw MobileDaemonError(code: "owner.unreachable", message: "the session host is not connected", retryable: true)
        }
        let version = request.snapshotVersions.compactMap { UInt16(exactly: $0) }.max()
        let attachment = try await mapped {
            try await TerminalAttachment.attach(
                endpoint: endpoint, target: TerminalAttachment.Target(tab: tab, generation: tree.generation),
                size: CellSize(cols: request.viewport.cols, rows: request.viewport.rows), claimGeometry: false,
                snapshotVersion: version, clientName: "cmux-next-mobile-link")
        }
        return await DaemonMobileTerminalAttachment.start(attachment, connection: connection, request: request,
                                                          title: tab.displayTitle)
    }

    private func tree() async throws -> DaemonTree {
        try await mapped { try await self.connection.snapshot().tree }
    }

    /// Daemon failures in the shared error shape (`owner.unreachable` is retryable).
    private func mapped<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as MobileDaemonError {
            throw error
        } catch {
            throw MobileDaemonError(code: "owner.unreachable", message: String(describing: error), retryable: true)
        }
    }
}
