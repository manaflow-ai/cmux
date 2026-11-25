import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextCompat
import CmuxNextServer
import Foundation

/// Switch Host…: the palette lists the Hosts section's rows (`MachineSectionRow.rows`); the chosen host's newest
/// workspace comes forward, else the section's own open (a new workspace, or its connect or sign-in path).
extension RemoteHandlers {
    static func bindSwitchHost(into registry: ActionRegistry, context: AppActionContext) {
        // action-wait-allow: focusing a workspace or the Hosts section's own open runs locally; nothing awaits a reply.
        registry.bind("machine.switch", run: { invocation in
            let services = context.services
            let wanted = invocation.target.flatMap { $0.kind == .machine ? $0.id : nil } ?? invocation["machine"]?.targetValue?.id
                ?? invocation["machine"]?.stringValue
            let hosts = services.hostsSidebar
            let rows = hosts.rows()
            guard let wanted, let row = rows.first(where: { $0.id == wanted }) ?? rows.first(where: { $0.name == wanted }) else {
                throw ActionFailure.invalidTarget(wanted.map(RemoteStrings.unknownMachine) ?? RemoteStrings.noHostChosen)
            }
            if row.isConnected, let newest = services.machines.anyDaemon(machine: row.id)?.store.workspaces.last {
                CloudHandlers.show(newest.id, context)
            } else {
                hosts.open(row)
            }
        })
    }
}
