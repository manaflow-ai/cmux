import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// Whole-group drag commits (`tab-groups-v1`): one daemon command each,
/// sent to the daemon that owns the group (`GroupOwnership`); a target on
/// another machine is refused (workspaces never mix machines). Groups exist
/// only on daemons that support them, so there is no fallback.
enum TabGroupMoves {
    typealias Completion = @MainActor (Bool) -> Void

    static func move(_ group: TabGroupID, to pane: PaneModel, index: Int, services: AppServices,
                     transaction: ClientTransactionID, completion: @escaping Completion) {
        guard let daemon = owner(of: group, target: pane, services: services),
              !refusesIncognitoCrossing(group, to: pane, services: services) else { return completion(false) }
        let target = pane.handle
        run("move-tab-group", daemon: daemon, completion: completion) { connection in
            _ = try await connection.moveTabGroup(group, to: target, index: index, transaction: transaction)
        }
    }

    /// `roomDecided`: see `TabMoves.toNewSplit`.
    static func toNewSplit(_ group: TabGroupID, pane: PaneModel, edge: PaneEdge, services: AppServices, roomDecided: Bool = false,
                           transaction: ClientTransactionID, completion: @escaping Completion) {
        guard let daemon = owner(of: group, target: pane, services: services),
              !refusesIncognitoCrossing(group, to: pane, services: services) else { return completion(false) }
        switch roomDecided ? SplitRoomDecision.split : services.splitRoom(for: pane, edge: edge) {
        case .split:
            break
        case .newColumn(let afterColumn, _):
            return toNewColumn(group, anchor: pane, afterColumn: afterColumn, services: services, transaction: transaction, completion: completion)
        case .refused(let reason):
            services.registry.refuse(reason)
            return completion(false)
        }
        let target = pane.handle
        run("move-tab-group-to-split", daemon: daemon, completion: completion) { connection in
            _ = try await connection.moveTabGroupToSplit(group, pane: target, edge: edge, transaction: transaction)
        }
    }

    static func toNewColumn(_ group: TabGroupID, anchor pane: PaneModel, afterColumn: DaemonColumnID?, services: AppServices,
                            transaction: ClientTransactionID, completion: @escaping Completion) {
        guard let daemon = owner(of: group, target: pane, services: services),
              !refusesIncognitoCrossing(group, to: pane, services: services) else { return completion(false) }
        let target = pane.handle
        let spawn = services.newColumnWidth(nextTo: pane)
        let width = spawn.width
        run("move-tab-group-to-column", daemon: daemon, completion: { ok in
            if ok { spawn.commit() }
            completion(ok)
        }) { connection in
            _ = try await connection.moveTabGroupToColumn(group, target: .pane(target), afterColumn: afterColumn, width: width,
                                                          transaction: transaction)
        }
    }

    /// Returns the new workspace key, or nil on failure.
    static func toNewWorkspace(_ group: TabGroupID, workspaceGroup: WorkspaceGroupID?, index: Int?, services: AppServices,
                               transaction: ClientTransactionID) async -> WorkspaceKey? {
        guard let daemon = GroupOwnership.daemon(holdingTabGroup: group, machines: services.machines) else { return nil }
        let before = Set(daemon.store.workspaces.compactMap(\.key))
        let name = newWorkspaceName(for: group, store: daemon.store, services: services)
        let key = await daemon.request("move-tab-group-to-new-workspace") { connection -> WorkspaceKey? in
            let result = try await connection.moveTabGroupToNewWorkspace(group, workspaceGroup: workspaceGroup, index: index,
                                                                         transaction: transaction)
            let created = if let key = result.key { key } else {
                try await connection.listWorkspaces().workspaces.compactMap(\.key).first { !before.contains($0) }
            }
            // The workspace takes the group's name, else its first tab's (R15).
            // A failed rename keeps the default name; the move stands.
            if let created, let name { _ = try? await connection.renameWorkspace(created, to: name) }
            return created
        }
        return key ?? nil
    }

    private static func newWorkspaceName(for group: TabGroupID, store: DaemonStore, services: AppServices) -> String? {
        let model = store.tabGroup(group)
        let first = model?.members.lazy.compactMap { member -> TabModel? in
            switch member {
            case .surface(let surface): store.tab(surface: surface)
            case .tab(let resource): store.tab(id: resource.rawValue)
            }
        }.first
        return NewWorkspaceName.forGroup(name: model?.name, firstTab: first.map { TabMoves.nameInput($0, services: services) })
    }

    /// True (and refused with a message) when `group` would move between an
    /// incognito window and a normal one.
    static func refusesIncognitoCrossing(_ group: TabGroupID, to pane: PaneModel, services: AppServices) -> Bool {
        guard services.windows.crossesIncognito(from: services.workspaceID(ofTabGroup: group), to: services.workspaceID(of: pane)) else {
            return false
        }
        services.registry.refuse(RefusalStrings.incognitoMismatch)
        return true
    }

    /// The daemon that owns `group`, when `pane` is on that machine too.
    static func owner(of group: TabGroupID, target pane: PaneModel, services: AppServices) -> DaemonService? {
        GroupOwnership.owner(ofTabGroup: group, sameMachineAs: services.daemon(for: pane), machines: services.machines)
    }

    private static func run(_ label: String, daemon: DaemonService,
                            completion: @escaping Completion, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        Task {
            let ok = await daemon.request(label, body) != nil
            completion(ok)
        }
    }
}
