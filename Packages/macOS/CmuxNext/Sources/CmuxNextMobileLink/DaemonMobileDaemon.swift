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
        let tree = try await tree()
        let personal = await personalState()
        return projection.state(tree, personal: personal?.state, sessionID: personal?.session)
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
        case .moveWorkspace(let workspace, let placement, let index):
            guard let key = projection.workspaceKey(workspace, in: tree) else {
                throw MobileDaemonError(code: "workspace.not_found", message: "\(workspace) is not on this Mac")
            }
            try await move(workspace, key: key, placement: placement, index: index, tree: tree)
        case .renameGroup(let group, let name):
            // Groups are personal (the home session's), like the Mac sidebar's.
            guard await personalState() != nil, await supports(DaemonCapabilities.shared.stateResources) else {
                throw MobileDaemonError(code: "proto.unsupported", message: "renaming groups is not supported by this Mac")
            }
            try await mapped { try await self.connection.state.updateWorkspaceGroup(group, name: name) }
        case .customizeWorkspace(let workspace, let color, let icon):
            guard let key = projection.workspaceKey(workspace, in: tree) else {
                throw MobileDaemonError(code: "workspace.not_found", message: "\(workspace) is not on this Mac")
            }
            guard await supports(DaemonCapabilities.shared.workspaceMetadata) else {
                throw MobileDaemonError(code: "proto.unsupported", message: "workspace colors and icons are not supported by this Mac")
            }
            _ = try await mapped {
                try await self.connection.setWorkspaceMetadata(key, color: Self.update(color), icon: Self.update(icon))
            }
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

    /// Files a workspace like a sidebar drag: through `workspace.place` on the
    /// personal order when the daemon serves it, else `move-workspace` on the
    /// tree order (no group changes without personal groups).
    private func move(_ workspace: String, key: WorkspaceKey, placement: MobileGroupPlacement, index: Int,
                      tree: DaemonTree) async throws {
        if let personal = await personalState(), await supports(DaemonCapabilities.shared.stateResources) {
            let current = personal.state.workspaces.first { $0.sessionID == personal.session && $0.workspaceKey == key }?.group
            let group: WorkspaceGroupID?
            let update: FieldUpdate<String>
            switch placement {
            case .keep: group = current; update = .unchanged
            case .ungrouped: group = nil; update = .clear
            case .group(let id): group = WorkspaceGroupID(rawValue: id); update = .set(id)
            }
            let position = projection.personalPlacementIndex(of: key, group: group, index: index,
                                                             personal: personal.state, sessionID: personal.session)
            try await mapped {
                try await self.connection.state.placeWorkspace(ResourceID(rawValue: workspace), group: update, index: position)
            }
            return
        }
        guard placement == .keep else {
            throw MobileDaemonError(code: "proto.unsupported", message: "moving workspaces between groups is not supported by this Mac")
        }
        let state = projection.state(tree)
        let others = state.workspaces.filter { $0.id != workspace }
        let target = min(index, others.count)
        _ = try await mapped { try await self.connection.moveWorkspace(key, to: target) }
    }

    /// The home session's personal state and this daemon's session id, when
    /// it serves `profiles-v1`.
    private func personalState() async -> (state: PersonalState, session: String)? {
        guard await connection.supportsProfiles, let session = await connection.identity?.sessionID,
              let state = try? await connection.listPersonal() else { return nil }
        return (state, session)
    }

    private func supports(_ capability: String) async -> Bool {
        await connection.identity?.supports(capability) == true
    }

    private static func update(_ change: MobileFieldChange) -> FieldUpdate<String> {
        switch change {
        case .unchanged: .unchanged
        case .clear: .clear
        case .set(let value): .set(value)
        }
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
