import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// Whole-group drag commits (`tab-groups-v1`): one daemon command each.
/// Groups exist only on daemons that support them, so there is no fallback.
enum TabGroupMoves {
    typealias Completion = @MainActor (Bool) -> Void

    static func move(_ group: TabGroupID, to pane: PaneModel, index: Int, services: AppServices,
                     transaction: ClientTransactionID, completion: @escaping Completion) {
        let target = pane.handle
        run("move-tab-group", services: services, transaction: transaction, completion: completion) { connection in
            _ = try await connection.moveTabGroup(group, to: target, index: index, transaction: transaction)
        }
    }

    static func toNewSplit(_ group: TabGroupID, pane: PaneModel, edge: PaneEdge, services: AppServices,
                           transaction: ClientTransactionID, completion: @escaping Completion) {
        switch services.splitRoom(for: pane, edge: edge) {
        case .split:
            break
        case .newColumn(let afterColumn, _):
            return toNewColumn(group, anchor: pane, afterColumn: afterColumn, services: services, transaction: transaction, completion: completion)
        case .refused(let reason):
            services.registry.refuse(reason)
            return completion(false)
        }
        let target = pane.handle
        run("move-tab-group-to-split", services: services, transaction: transaction, completion: completion) { connection in
            _ = try await connection.moveTabGroupToSplit(group, pane: target, edge: edge, transaction: transaction)
        }
    }

    static func toNewColumn(_ group: TabGroupID, anchor pane: PaneModel, afterColumn: DaemonColumnID?, services: AppServices,
                            transaction: ClientTransactionID, completion: @escaping Completion) {
        let target = pane.handle
        run("move-tab-group-to-column", services: services, transaction: transaction, completion: completion) { connection in
            _ = try await connection.moveTabGroupToColumn(group, target: .pane(target), afterColumn: afterColumn, transaction: transaction)
        }
    }

    /// Returns the new workspace key, or nil on failure.
    static func toNewWorkspace(_ group: TabGroupID, workspaceGroup: WorkspaceGroupID?, index: Int?, services: AppServices,
                               transaction: ClientTransactionID) async -> WorkspaceKey? {
        let before = Set(services.daemon.store.workspaces.compactMap(\.key))
        let key = await services.daemon.commit("move-tab-group-to-new-workspace", patch: .custom { _ in }, transaction: transaction,
                                               expectEcho: false) { connection -> WorkspaceKey? in
            let result = try await connection.moveTabGroupToNewWorkspace(group, workspaceGroup: workspaceGroup, index: index,
                                                                         transaction: transaction)
            if let key = result.key { return key }
            return try await connection.listWorkspaces().workspaces.compactMap(\.key).first { !before.contains($0) }
        }
        return key ?? nil
    }

    private static func run(_ label: String, services: AppServices, transaction: ClientTransactionID,
                            completion: @escaping Completion, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        Task {
            let ok = await services.daemon.commit(label, patch: .custom { _ in }, transaction: transaction, expectEcho: false, body) != nil
            completion(ok)
        }
    }
}
