import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemonService
import Foundation

// `cmux cloud list-machines`: the app's own Cloud machine list, the one the
// sidebar's Cloud machines show (``MachineRegistry/cloud``). Read only, so an
// agent can check whether its machine already exists before it creates one.
extension CloudHandlers {
    static func bindListActions(into registry: ActionRegistry, context: AppActionContext) {
        let cloud = context.services.cloud
        // Signed out still answers (`signed_in: false`, no machines); only a build or a
        // policy that runs no Cloud at all refuses, since its list would be empty for no reason.
        bind("cloudListMachines", registry, reason: { cloud.unavailableReason }) { invocation in
            try listMachines(invocation, context)
        }
    }

    /// A person's run shows the machines where they already live, the right
    /// sidebar's Cloud section. Any other run (CLI, MCP, a script) gets the
    /// list as `action.run`'s `result` and nothing changes on screen.
    static func listMachines(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        guard origin(of: invocation) != .user else {
            guard let controller = context.activeWindow else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
            guard controller.showRightSidebar(.machines, focus: invocation.allowsViewChange) else {
                throw ActionFailure.needsAppCapability("right-sidebar")
            }
            return
        }
        let cloud = context.services.cloud
        result("list Cloud machines", context) {
            // At launch the session may still be restoring: signed out until it is, which
            // would answer an empty list for an account that has machines.
            if cloud.auth.isRestoring { await cloud.auth.awaitRestored() }
            // The list is fetched at sign-in, after every machine change and on
            // activation, so a loaded store is current: no request. One that has
            // not loaded yet takes the same refresh the sidebar's does.
            if cloud.isSignedIn, !cloud.hasLoadedMachines { await cloud.refresh() }
            // An unloaded list is not an empty one: answering "no machines" would
            // send an idempotent caller off to create a second machine.
            if cloud.isSignedIn, !cloud.hasLoadedMachines {
                throw ActionFailure(message: CloudStrings.machineListUnavailable)
            }
            return machineListFields(context)
        }
    }

    /// `cloud list-machines`' result: `machines` (one object per machine in
    /// the store) and `account`. `account` holds only what the store knows:
    /// it keeps no plan limits (`max_active_vms`), and a count of machines is
    /// no entitlement (0 is a closed plan, null an uncapped one), so the
    /// answer leaves `limits` out rather than guess.
    static func machineListFields(_ context: AppActionContext) -> [String: ActionResultValue] {
        let cloud = context.services.cloud
        // The list is fetched for the account's team when it has one (the
        // `X-Cmux-Team-Id` the API client sends), else for the person alone.
        let owner = cloud.auth.teamID == nil ? "personal" : "team"
        let machines = context.services.machines.cloud.map { listedMachine($0, owner: owner) }
        return [
            "machines": .array(machines),
            "count": .int(machines.count),
            "account": .object(["signed_in": .bool(cloud.isSignedIn)]),
        ]
    }

    /// One machine of the list, with the target the other Cloud verbs take.
    static func listedMachine(_ session: CloudMachineSession, owner: String) -> ActionResultValue {
        .object([
            "machine_id": .string(session.machineID),
            "target": .string("machine:\(session.machineID)"),
            "title": .string(session.machine.title),
            "status": .string(listedStatus(session)),
            "owner": .string(owner),
            "created_at": session.machine.createdAt.map { .string($0.formatted(.iso8601)) } ?? .null,
        ])
    }

    /// The machine's status: the record's (``CloudMachineSession/effectiveStatus``),
    /// never the progress stage, which calls a paused machine `failed` (it
    /// shows "paused, click to resume" as a stopped stage).
    static func listedStatus(_ session: CloudMachineSession) -> String {
        session.effectiveStatus.rawValue
    }
}
