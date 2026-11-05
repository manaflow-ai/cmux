import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemonService
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextSettings
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
        // A first load that outlasts `listLoadWait` answers what the store has
        // now (`loaded: false`, `pending: true`) inside `action.run`'s result
        // deadline; the refresh keeps going and the next run reads its list.
        result("list Cloud machines", context, pendingAfter: listLoadWait, pending: machineListFields(context, loaded: false)) {
            // At launch the session may still be restoring: signed out until it is.
            if cloud.auth.isRestoring { await cloud.auth.awaitRestored() }
            // The list is fetched at sign-in, after every machine change and on
            // activation, so a loaded store is current: no request. One that has
            // not loaded yet takes the same refresh the sidebar's does.
            // One loaded for another team than the signed-in one is not loaded.
            if cloud.isSignedIn, !cloud.hasLoadedCurrentMachines { await cloud.refresh() }
            return machineListFields(context, loaded: cloud.hasLoadedCurrentMachines)
        }
    }

    /// How long a run waits for the store's first load before it answers
    /// `loaded: false`: inside `action.run`'s 40 s result deadline.
    static let listLoadWait: Duration = .seconds(25)

    /// `cloud list-machines`' result: `loaded`, `machines` (one object per
    /// machine in the store), `count`, `creating` and `account`.
    ///
    /// `creating` lists this app's creates whose machine the server has not returned yet
    /// (``CloudCreations``): the name asked for, and `creating` or `failed` with its reason.
    /// A machine joins `machines` only when its create returns, which can take minutes, so an
    /// agent that checks for its machine by name sees one still on its way and makes no second.
    ///
    /// `loaded` is whether the store holds a list the server answered for
    /// the signed-in user and team (``CloudService/hasLoadedCurrentMachines``).
    /// Before that (a relaunch, signed out, a failed first list, another
    /// team's list) the store's list says nothing about which machines exist, so the answer has no machines: a caller never reads
    /// "not loaded yet" as "none" and creates a second one.
    ///
    /// `account` holds only what the store knows: it keeps no plan limits
    /// (`max_active_vms`), and a count of machines is no entitlement (0 is a
    /// closed plan, null an uncapped one), so the answer leaves `limits` out.
    static func machineListFields(_ context: AppActionContext, loaded: Bool) -> [String: ActionResultValue] {
        let cloud = context.services.cloud
        // The list is fetched for the account's team when it has one (the
        // `X-Cmux-Team-Id` the API client sends), else for the person alone.
        let owner = cloud.auth.teamID == nil ? "personal" : "team"
        let machines = loaded ? context.services.machines.cloud.map { listedMachine($0, owner: owner) } : []
        return [
            "loaded": .bool(loaded),
            "machines": .array(machines),
            "count": .int(machines.count),
            "creating": .array(cloud.creations.all.filter { $0.session == nil }.map(listedCreation)),
            "account": .object(["signed_in": .bool(cloud.isSignedIn)]),
        ]
    }

    /// One create still on its way: its id, the name it asked for (null: the server picks one)
    /// and `creating`, or `failed` with the reason (it stays in the sidebar with Retry).
    static func listedCreation(_ creation: CloudMachineCreation) -> ActionResultValue {
        var row: [String: ActionResultValue] = [
            "creation_id": .string(creation.id.uuidString.lowercased()),
            "name": creation.request.name.map(ActionResultValue.string) ?? .null,
            "status": .string("creating"),
        ]
        if case .failed(let reason) = creation.phase {
            row["status"] = .string("failed")
            row["reason"] = .string(reason)
        }
        return .object(row)
    }

    /// One machine of the list, with the target the other Cloud verbs take.
    static func listedMachine(_ session: CloudMachineSession, owner: String) -> ActionResultValue {
        .object([
            "machine_id": .string(session.machineID),
            "target": .string("machine:\(session.machineID)"),
            "title": .string(session.machine.title),
            "status": .string(listedStatus(session)),
            "owner": .string(owner),
            "created_by": session.machine.createdBy.map(ActionResultValue.string) ?? .null,
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

// `cmux cloud computer-control --machine <id> --action status|take_over|hand_back|request_human`
// (Chief computer take-over): who drives the Chief's computer on a Cloud machine. The lease and its
// rules live in ``ChiefComputerControlStore`` (CmuxNextHostedChief), this app's one owner of it; the
// profile's Computer tab changes the same store (``AppServices/chiefComputerControlSource(agent:machine:)``).
//
// Trust: no new policy. `status` answers any local caller (the Chief's `cloud_computer` tool reads it
// before each input). A change from another client (`remote`: a phone, another Mac) is refused,
// default deny. Only the person's own gesture takes over or gives back a computer the person took
// over (`computer.user_origin_required` otherwise), so a Chief cannot take control back from them;
// a local caller may ask the person (request_human), and an automated hand_back ends only that ask.
extension CloudHandlers {
    static func bindComputerControl(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services, store = services.cloud.computerControl
        store.onHumanRequested = { [weak services] machine, state in services.map { postComputerAsk($0, machine: machine, reason: state.reason) } }
        store.onAskEnded = { [weak services] machine in services?.notifications.desktop.withdraw(["chief-computer." + machine]) }
        let bound = registry.bindEffect("cloud.computerControl", requires: nil) { invocation in
            computerControlEffect(invocation, store: store, knows: { services.machines.session($0) != nil })
        }
        assert(bound, "cloud.computerControl is not in the action catalog")
    }

    /// One run: the change on this turn, then `{machine, holder, since_ms, reason?}` as the result.
    static func computerControlEffect(_ invocation: ActionInvocation, store: ChiefComputerControlStore,
                                      knows: (String) -> Bool) -> ActionEffect {
        do throws(ChiefComputerControlStore.Refusal) {
            let (machine, state) = try store.run(machine: invocation["machine"]?.stringValue, action: invocation["action"]?.stringValue,
                                                 reason: invocation["reason"]?.stringValue, fromAnotherClient: origin(of: invocation) == .remote,
                                                 // A nested run inside a CLI or agent run stays automation (the run scope's origin).
                                                 byPerson: invocation.isPersonsOwnRun && origin(of: invocation) == .user, knows: knows)
            var fields: [String: ActionResultValue] = ["machine": .string(machine), "holder": .string(state.holder.rawValue), "since_ms": .int(Int(state.sinceMs))]
            if let reason = state.reason { fields["reason"] = .string(reason) }
            return .applied(result: { [fields] in .success(fields) })
        } catch {
            return .refused(error.message)
        }
    }

    /// The Chief's ask as a banner, by the agent source's notification rules (desktop, quiet hours,
    /// sounds, Dock bounce), as hand-offs and Runs post theirs; withdrawn when the ask ends.
    private static func postComputerAsk(_ services: AppServices, machine: String, reason: String?) {
        let center = services.notifications
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = services.appActiveSource()
        arrival.soundEvent = .message
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        var decision = NotificationPolicy(prefs: center.preferences).decide(arrival)
        guard !decision.acknowledge, center.desktopPostingEnabled else { return }
        center.soundGate.admit(&decision, cooldownSeconds: center.preferences.sounds.cooldownSeconds)
        let text = ChiefComputerControlStore.askText(machine: services.machines.session(machine)?.machine.title ?? machine, reason: reason)
        if decision.desktop {
            center.desktop.post(id: "chief-computer." + machine, title: text.title, body: text.body, surface: nil, workspace: nil, defaultSound: decision.sound == "default")
        }
        if let sound = decision.sound, !decision.desktop || sound != "default" { center.soundGate.player.play(sound, volume: decision.soundVolume, banner: decision.desktop) }
        if let mode = decision.bounce { center.dockAttention.bounce(untilActive: mode == .untilActive) }
    }
}
