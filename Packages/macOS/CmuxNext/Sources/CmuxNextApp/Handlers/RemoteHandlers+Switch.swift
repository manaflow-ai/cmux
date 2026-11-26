import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextCompat
import CmuxNextServer
import CmuxNextWindowRules
import Foundation

/// Switch Host…: the palette lists the Hosts section's rows (`MachineSectionRow.rows`); the chosen host's newest
/// workspace comes forward, else the section's own open (a new workspace, or its connect or sign-in path).
extension RemoteHandlers {
    static func bindSwitchHost(into registry: ActionRegistry, context: AppActionContext) {
        // action-wait-allow: focusing a workspace or the Hosts section's own open runs locally; nothing awaits a reply.
        registry.bind("machine.switch", run: { invocation in
            let services = context.services
            let hosts = services.hostsSidebar, rows = hosts.rows()
            // Rust's `handlers_verbs::switch_host`: a machine target, else the argument; its row by id, else by name.
            let pick = WindowRules().switchHost(target: invocation.target.map { .init(kind: $0.kind.rawValue, id: $0.id) }, machineTarget: invocation["machine"]?.targetValue?.id,
                                                machineText: invocation["machine"]?.stringValue, rows: rows.map { .init(id: $0.id, name: $0.name) })
            guard let wanted = pick?.wanted, let row = pick?.row.flatMap({ rows.indices.contains($0) ? rows[$0] : nil }) else {
                throw ActionFailure.invalidTarget(pick?.wanted.map(RemoteStrings.unknownMachine) ?? RemoteStrings.noHostChosen)
            }
            if row.isConnected, let newest = services.machines.anyDaemon(machine: row.id)?.store.workspaces.last {
                CloudHandlers.show(newest.id, context)
            } else {
                hosts.open(row)
            }
        })
    }
}
