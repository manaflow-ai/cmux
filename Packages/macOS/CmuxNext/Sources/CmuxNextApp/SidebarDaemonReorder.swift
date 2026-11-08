import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// A reorder on a machine whose order is not personal: that daemon's one
/// flat workspace order, sent as `move-workspace` commands. Beside
/// SidebarBridge (its type is at its size limit).
@MainActor
enum SidebarDaemonReorder {
    /// `edit`, when given, is the pending edit showing the move; it settles
    /// once the commands replied (their events are in the store) or failed.
    static func reorder(_ ids: [SidebarWorkspaceID], to position: DropPosition, in sections: [SidebarRowSection],
                        edit: SidebarPendingEdits.Token? = nil, bridge: SidebarBridge) {
        guard case .machine(let machine) = position.section, let target = bridge.services.machines.daemon(machine: machine.rawValue),
              let (daemon, _) = bridge.sameMachine(ids), daemon === target
        else { return failed(edit, bridge) }
        // Groups are personal: the machine's own order is one flat list.
        let entries = daemon.store.workspaces.map { WorkspaceMovePlan.Entry(id: $0.id, group: nil) }
        guard let commands = WorkspaceMovePlan(window: sections).commands(for: position, moving: ids, daemon: entries, groups: false)
        else { return failed(edit, bridge) }
        run(commands, on: daemon, edit: edit, failed: bridge.saveFailed(.reorder(ids, to: position)), bridge: bridge)
    }

    private static func failed(_ edit: SidebarPendingEdits.Token?, _ bridge: SidebarBridge) {
        bridge.rows.edits.settle(edit)
        bridge.resync()
    }

    /// Sends reorder commands one after another in one task: each index
    /// assumes the previous command applied. A rejection re-syncs and says why (#26382).
    private static func run(_ commands: [WorkspaceMovePlan.Command], on daemon: DaemonService, edit: SidebarPendingEdits.Token?,
                            failed: @escaping @MainActor (ActionWorkFailure) -> Void, bridge: SidebarBridge) {
        let keys = Dictionary(daemon.store.workspaces.compactMap { model in model.key.map { (model.id, $0) } },
                              uniquingKeysWith: { first, _ in first })
        // `services` pins the app's services while the commands run, so a
        // re-sync after a rejection never reads a freed owner (cx-6so P1b).
        Task { [weak bridge, services = bridge.services] in
            for command in commands {
                let failure: ActionWorkFailure?
                switch command {
                case .move(let id, let index):
                    guard let key = keys[id] else { continue }
                    failure = await daemon.intentSender("move-workspace", .moveWorkspace(key: key, index: index)) { c in
                        _ = try await c.moveWorkspace(key, to: index)
                    }()
                case .place:
                    // Never planned without groups (`groups: false`).
                    failure = ActionWorkFailure("move-workspace")
                }
                if let failure {
                    withExtendedLifetime(services) {
                        bridge?.rows.edits.settle(edit)
                        failed(failure)
                    }
                    return
                }
            }
            bridge?.rows.edits.settle(edit)
        }
    }
}
