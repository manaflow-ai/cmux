import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// The owner of the sidebar layout as the service reaches it: the home
/// daemon's `sidebar-layout-v1` (or a fake in tests).
@MainActor
protocol SidebarLayoutRemote: AnyObject {
    /// The store serves the layout and the connection is up.
    var isAvailable: Bool { get }
    /// Changes when the owner's personal state changes (a refetch signal).
    var changeToken: UInt64 { get }
    func get() async throws -> SidebarLayoutDocument
    func update(_ op: SidebarLayoutOp, key: String) async throws -> SidebarLayoutDocument
    /// Workspaces pinned with the legacy flag (`workspace-pin-v1`) as layout
    /// refs, per session whose tree has loaded and that has such a pin (the
    /// one-time move into tiles).
    var legacyPins: [LegacyPins] { get }
    /// Clears the legacy flag of `refs` in their session's own store, once
    /// their tiles are confirmed. The cleared flag is the move's done mark:
    /// it is per session, so every Mac and client of the session sees it.
    func clearLegacyPins(_ refs: [LayoutItemRef])
}

/// One session's legacy pinned workspaces, in its sidebar order, with
/// their names (stored with their tiles).
struct LegacyPins: Hashable {
    var session: String
    var refs: [LayoutItemRef]
    var labels: [LayoutItemRef: String] = [:]
}

extension SidebarLayoutRemote {
    var legacyPins: [LegacyPins] { [] }
    func clearLegacyPins(_ refs: [LayoutItemRef]) {}
}

/// Whether an owner call failed because the connection went away (the
/// intent is resent with its key on reconnect) rather than a reject.
nonisolated func isDisconnect(_ error: any Error) -> Bool {
    switch error as? DaemonError {
    case .notConnected?, .connectionClosed?, .daemonShutdown?: true
    default: false
    }
}

/// The home daemon (`services.machines.local`).
@MainActor
final class DaemonSidebarLayoutRemote: SidebarLayoutRemote {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    private var daemon: DaemonService { services.machines.local }

    var isAvailable: Bool { daemon.connection != nil && daemon.supports(DaemonCapabilities.shared.sidebarLayout) }
    var changeToken: UInt64 { daemon.store.personal.revision }

    var legacyPins: [LegacyPins] {
        let refs = WorkspaceLayoutRefs(machines: services.machines)
        return services.machines.daemons.compactMap { daemon in
            guard let session = daemon.store.registryID, !daemon.store.isProvisional else { return nil }
            var pins = LegacyPins(session: session, refs: [])
            for workspace in daemon.store.workspaces where workspace.pinned {
                guard let ref = refs.ref(for: workspace, on: daemon) else { continue }
                pins.refs.append(ref)
                pins.labels[ref] = workspace.displayName
            }
            return pins.refs.isEmpty ? nil : pins
        }
    }

    func clearLegacyPins(_ refs: [LayoutItemRef]) {
        let resolver = WorkspaceLayoutRefs(machines: services.machines)
        for ref in refs {
            guard let (workspace, daemon) = resolver.workspace(for: ref), workspace.pinned, let key = workspace.key,
                  daemon.supports(DaemonCapabilities.shared.workspacePin) else { continue }
            daemon.send("clear-legacy-workspace-pin") { _ = try await $0.setWorkspaceMetadata(key, pinned: false) }
        }
    }

    func get() async throws -> SidebarLayoutDocument {
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        return try Self.document(try await SidebarLayoutStateClient(connection: connection).get())
    }

    func update(_ op: SidebarLayoutOp, key: String) async throws -> SidebarLayoutDocument {
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        let wire = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(op))
        return try Self.document(try await SidebarLayoutStateClient(connection: connection).update(op: wire, idempotencyKey: key).layout)
    }

    /// `SidebarLayoutSnapshot` (revision as a decimal string) -> document.
    nonisolated static func document(_ value: JSONValue) throws -> SidebarLayoutDocument {
        struct Snapshot: Decodable {
            var revision: String
            var sections: [LayoutSection]
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(value))
        return SidebarLayoutDocument(revision: UInt64(snapshot.revision) ?? 0, sections: snapshot.sections)
    }
}
