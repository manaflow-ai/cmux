import Foundation
public import Observation
import os

public enum DaemonConnectionState: Sendable, Equatable {
    case connecting
    case connected(DaemonIdentity)
    case disconnected(String)
    case failed(String)
}

@Observable @MainActor
public final class DaemonStore {
    public private(set) var workspaces: [WorkspaceModel] = []
    public private(set) var groups: [WorkspaceGroupSnapshot] = []
    public private(set) var connectionState: DaemonConnectionState = .connecting
    public private(set) var generation: DaemonGeneration?
    public private(set) var registryID: String?
    public private(set) var workspaceRevision: UInt64 = 0
    /// Recent notifications, newest last (bounded).
    public private(set) var notifications: [DaemonNotification] = []
    /// True once the first snapshot is applied.
    public private(set) var isLoaded = false
    /// Client transaction ids the daemon echoed, newest last (bounded). The
    /// App reconciles optimistic tab-drag state against these.
    public private(set) var confirmedTransactions: [ClientTransactionID] = []
    /// Called once per echoed transaction id, on the main actor.
    @ObservationIgnored public var onTransactionConfirmed: ((ClientTransactionID) -> Void)?
    @ObservationIgnored public var transactionLimit = 64

    @ObservationIgnored private var tabsBySurface: [SurfaceID: TabModel] = [:]
    @ObservationIgnored private var panesByHandle: [PaneID: PaneModel] = [:]
    @ObservationIgnored private var screensByHandle: [ScreenID: ScreenModel] = [:]
    @ObservationIgnored private var workspacesByHandle: [WorkspaceHandle: WorkspaceModel] = [:]
    @ObservationIgnored private var agentsBySurface: [SurfaceID: AgentStatus] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.store")
    @ObservationIgnored public var notificationLimit = 200

    public init() {}

    // MARK: Lookup

    public func workspace(key: WorkspaceKey) -> WorkspaceModel? { workspaces.first { $0.key == key } }
    public func workspace(handle: WorkspaceHandle) -> WorkspaceModel? { workspacesByHandle[handle] }
    public func screen(_ handle: ScreenID) -> ScreenModel? { screensByHandle[handle] }
    public func pane(_ handle: PaneID) -> PaneModel? { panesByHandle[handle] }
    public func tab(surface: SurfaceID) -> TabModel? { tabsBySurface[surface] }
    public func tab(terminal: TerminalID) -> TabModel? { tabsBySurface.values.first { $0.terminalID == terminal } }

    // MARK: Applying state

    /// What the caller must do after `apply(_:)`.
    public enum Followup: Equatable, Sendable {
        case none
        /// Refetch `list-workspaces` and apply it.
        case resync
    }

    /// Replaces the tree, reusing models by durable identity.
    public func apply(snapshot tree: DaemonTree) {
        generation = tree.generation ?? generation
        registryID = tree.registryID ?? registryID
        workspaceRevision = tree.workspaceRevision
        groups = tree.groups
        workspaces = reconcile(workspaces, with: tree.workspaces, id: WorkspaceModel.identity, make: WorkspaceModel.init) { $0.update($1) }
        isLoaded = true
        rebuildIndexes()
    }

    /// Applies one event in place. Returns `.resync` when the event cannot be
    /// applied exactly (revision gap, generation change, coarse invalidation).
    @discardableResult
    public func apply(_ event: DaemonEvent) -> Followup {
        let followup = applyState(event)
        if let transaction = event.clientTransactionID, !confirmedTransactions.contains(transaction) {
            confirmedTransactions.append(transaction)
            if confirmedTransactions.count > transactionLimit {
                confirmedTransactions.removeFirst(confirmedTransactions.count - transactionLimit)
            }
            onTransactionConfirmed?(transaction)
        }
        return followup
    }

    private func applyState(_ event: DaemonEvent) -> Followup {
        switch event {
        case .connected(let identity, _):
            connectionState = .connected(identity)
            return .resync
        case .disconnected(let reason):
            connectionState = .disconnected(reason)
            return .none

        case .workspaceAdded(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                if let existing = store.workspaces.first(where: { $0.id == WorkspaceModel.identity(delta.entity) }) {
                    existing.update(delta.entity)
                } else {
                    let index = min(max(delta.index ?? store.workspaces.count, 0), store.workspaces.count)
                    store.workspaces.insert(WorkspaceModel(delta.entity), at: index)
                }
            }
        case .workspaceClosed(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                store.workspaces.removeAll { $0.id == WorkspaceModel.identity(delta.entity) }
            }
        case .workspaceRenamed(let delta), .workspaceChanged(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                store.workspaces.first { $0.id == WorkspaceModel.identity(delta.entity) }?.update(delta.entity)
            }
        case .workspaceMoved(let delta):
            return applyWorkspaceDelta(delta) { store, delta in
                let id = WorkspaceModel.identity(delta.entity)
                guard let from = store.workspaces.firstIndex(where: { $0.id == id }) else { return }
                let model = store.workspaces.remove(at: from)
                model.update(delta.entity)
                let index = min(max(delta.index ?? store.workspaces.count, 0), store.workspaces.count)
                store.workspaces.insert(model, at: index)
            }

        case .screenAdded(let delta):
            guard let workspace = workspacesByHandle[delta.workspace] else { return .resync }
            if let existing = workspace.screens.first(where: { $0.id == ScreenModel.identity(delta.entity) }) {
                existing.update(delta.entity)
            } else {
                let index = min(max(delta.index ?? workspace.screens.count, 0), workspace.screens.count)
                workspace.screens.insert(ScreenModel(delta.entity), at: index)
            }
            rebuildIndexes()
            return .none
        case .screenClosed(let delta):
            guard let workspace = workspacesByHandle[delta.workspace] else { return .none }
            workspace.screens.removeAll { $0.handle == delta.screen }
            rebuildIndexes()
            return .none
        case .screenRenamed(let delta):
            guard let screen = screensByHandle[delta.screen] else { return .resync }
            screen.update(delta.entity)
            rebuildIndexes()
            return .none

        case .paneAdded(let delta):
            guard let screen = screensByHandle[delta.screen] else { return .resync }
            if let existing = screen.panes.first(where: { $0.id == PaneModel.identity(delta.entity) }) {
                existing.update(delta.entity)
            } else {
                let index = min(max(delta.index ?? screen.panes.count, 0), screen.panes.count)
                screen.panes.insert(PaneModel(delta.entity), at: index)
            }
            rebuildIndexes()
            // The layout that places the pane arrives as `layout-changed`.
            return .none
        case .paneClosed(let delta):
            screensByHandle[delta.screen]?.panes.removeAll { $0.handle == delta.pane }
            rebuildIndexes()
            return .none

        case .tabAdded(let delta):
            guard let pane = panesByHandle[delta.pane] else { return .resync }
            if let existing = pane.tabs.first(where: { $0.id == TabModel.identity(delta.entity) }) {
                existing.update(delta.entity)
            } else {
                let index = min(max(delta.index ?? pane.tabs.count, 0), pane.tabs.count)
                let tab = TabModel(delta.entity)
                tab.agent = agentsBySurface[delta.surface]
                pane.tabs.insert(tab, at: index)
            }
            rebuildIndexes()
            return .none
        case .tabClosed(let delta):
            panesByHandle[delta.pane]?.tabs.removeAll { $0.surface == delta.surface }
            rebuildIndexes()
            return .none
        case .tabRenamed(let delta), .tabChanged(let delta):
            guard let tab = tabsBySurface[delta.surface] else { return .resync }
            tab.update(delta.entity)
            return .none

        case .treeChanged, .layoutChanged, .overflow:
            return .resync

        case .titleChanged(let surface, let title):
            tabsBySurface[surface]?.title = title
            return .none
        case .surfaceResized(let surface, let size):
            tabsBySurface[surface]?.size = size
            return .none
        case .surfaceExited(let surface):
            tabsBySurface[surface]?.dead = true
            return .none
        case .notification(let notification):
            notifications.append(notification)
            if notifications.count > notificationLimit { notifications.removeFirst(notifications.count - notificationLimit) }
            // The daemon retains a marker only for an inactive target and
            // follows with `tree-changed`, which settles the exact state.
            return .none
        case .agentChanged(let status):
            agentsBySurface[status.surface] = status
            tabsBySurface[status.surface]?.agent = status
            return .none

        case .scrollChanged, .bell, .frontendProjectionChanged, .terminalRegistryChanged, .client, .unknown:
            return .none
        case .daemonShutdown:
            connectionState = .disconnected("daemon shut down")
            return .none
        }
    }

    /// Seeds agent state (`list-agents`), e.g. after connect.
    public func apply(agents: [AgentStatus]) {
        agentsBySurface = Dictionary(agents.map { ($0.surface, $0) }, uniquingKeysWith: { $1 })
        for (surface, tab) in tabsBySurface { tab.agent = agentsBySurface[surface] }
    }

    /// Marks the connection permanently failed (incompatible daemon).
    public func markFailed(_ message: String) {
        connectionState = .failed(message)
    }

    private func applyWorkspaceDelta(_ delta: WorkspaceDelta, _ body: (DaemonStore, WorkspaceDelta) -> Void) -> Followup {
        if let generation = delta.generation, let current = self.generation, generation != current { return .resync }
        if let registry = delta.registryID, let current = registryID, registry != current { return .resync }
        if delta.workspaceRevision <= workspaceRevision { return .none }
        guard delta.workspaceRevision == workspaceRevision + 1 else { return .resync }
        body(self, delta)
        workspaceRevision = delta.workspaceRevision
        rebuildIndexes()
        return .none
    }

    private func rebuildIndexes() {
        var tabs: [SurfaceID: TabModel] = [:]
        var panes: [PaneID: PaneModel] = [:]
        var screens: [ScreenID: ScreenModel] = [:]
        var byHandle: [WorkspaceHandle: WorkspaceModel] = [:]
        for workspace in workspaces {
            byHandle[workspace.handle] = workspace
            for screen in workspace.screens {
                screens[screen.handle] = screen
                for pane in screen.panes {
                    panes[pane.handle] = pane
                    for tab in pane.tabs {
                        tabs[tab.surface] = tab
                        if tab.agent == nil, let agent = agentsBySurface[tab.surface] { tab.agent = agent }
                    }
                }
            }
        }
        tabsBySurface = tabs
        panesByHandle = panes
        screensByHandle = screens
        workspacesByHandle = byHandle
    }

    // MARK: Driving from a connection

    /// Consumes `connection.events` until the connection closes: resyncs on
    /// connect and whenever an event cannot be applied exactly. Events that
    /// arrive during a resync wait in the stream and apply after it; stale
    /// workspace deltas are dropped by the revision gate and other deltas
    /// are idempotent.
    public func run(connection: DaemonConnection) async {
        do {
            for try await event in connection.events {
                if apply(event) == .resync {
                    await resync(connection: connection, seedAgents: isConnectEvent(event))
                }
            }
        } catch {
            markFailed(String(describing: error))
        }
    }

    private func isConnectEvent(_ event: DaemonEvent) -> Bool {
        if case .connected = event { return true }
        return false
    }

    private func resync(connection: DaemonConnection, seedAgents: Bool) async {
        do {
            let tree = try await connection.request(ListWorkspacesRequest())
            apply(snapshot: tree)
            if seedAgents {
                let agents = try await connection.request(ListAgentsRequest())
                apply(agents: agents.agents)
            }
        } catch {
            logger.error("resync failed: \(String(describing: error), privacy: .public)")
        }
    }
}
