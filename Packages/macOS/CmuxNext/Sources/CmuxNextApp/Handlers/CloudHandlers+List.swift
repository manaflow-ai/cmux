import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSidebar
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

    /// Every run (a person's, the CLI, MCP, a script) gets the list as
    /// `action.run`'s `result` and nothing changes on screen.
    static func listMachines(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
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
        let machines: [[String: Any]] = context.services.machines.cloud.map { session in
            let machine = session.machine
            return ["machineId": session.machineID, "title": machine.title, "status": session.effectiveStatus.rawValue,
                    "createdBy": machine.createdBy as Any, "createdAt": machine.createdAt?.timeIntervalSince1970 as Any,
                    "failure": machine.lastChangeFailure.map { ["code": $0.code, "message": $0.message] } as Any].compacted
        }
        let creating: [[String: Any]] = cloud.creations.all.filter { $0.session == nil }.map { creation in
            var failed: String?
            if case .failed(let reason) = creation.phase { failed = reason }
            return ["creationId": creation.id.uuidString.lowercased(), "name": creation.request.name as Any, "failed": failed as Any].compacted
        }
        // The list is fetched for the account's team when it has one (the `X-Cmux-Team-Id` the API
        // client sends), else for the person alone.
        let list: [String: Any] = ["loaded": loaded, "team": cloud.auth.teamID != nil, "signedIn": cloud.isSignedIn,
                                   "machines": machines, "creating": creating]
        return CloudHandlerRules().fields("cloud_handler_machine_list", ["list": list])
    }
}

extension CloudHandlers {
    /// A rules answer as a sheet's or a caller's ``CloudAnswer``; `none` when it found nothing.
    static func cloudAnswer(_ title: String, _ answer: CloudHandlerRules.Answer, none: String = "") -> CloudAnswer {
        CloudAnswer(title: title, text: answer.text ?? none, copyable: answer.copyable, fields: answer.fields)
    }
}

extension CloudHandlers {
    /// `cloud resize-machine`'s checked `--size` and `--disk` (the rules' `resize`): what the
    /// resize call sends and the fields it answers (`size`, `disk_gib`, as given).
    typealias Resize = (cpu: Int?, memoryMb: Int?, storageMb: Int?, fields: [String: ActionResultValue])

    /// The app server's `cloud.machine.resize` args: `{machine, size: {cpu?, memory_mb?, disk_mb?}}`, only what was given.
    static func resizeArgs(_ request: Resize, machine: String) -> [String: JSONValue] {
        var size: [String: JSONValue] = [:]
        if let cpu = request.cpu { size["cpu"] = .number(Double(cpu)) }
        if let memoryMb = request.memoryMb { size["memory_mb"] = .number(Double(memoryMb)) }
        if let storageMb = request.storageMb { size["disk_mb"] = .number(Double(storageMb)) }
        return ["machine": .string(machine), "size": .object(size)]
    }

    static func resizeRequest(_ invocation: ActionInvocation) throws -> Resize {
        let checked = try CloudHandlerRules().arg("resize", invocation) as? [String: Any] ?? [:]
        var fields: [String: ActionResultValue] = [:]
        if let size = checked["size"] as? String { fields["size"] = .string(size) }
        if let disk = checked["diskGib"] as? Int { fields["disk_gib"] = .int(disk) }
        return (checked["cpu"] as? Int, checked["memoryMb"] as? Int, checked["storageMb"] as? Int, fields)
    }
}

extension CloudHandlers {
    /// `cloud machine-status`'s text and fields, from the machine's record, its stats and its cost.
    static func status(_ session: CloudMachineSession, _ stats: CloudMachineStats, now: Date = Date()) -> (text: String, fields: [String: ActionResultValue]) {
        let machine = session.machine
        var facts: [String: Any] = [
            "machineId": session.machineID, "title": machine.title, "status": session.effectiveStatus.rawValue, "state": stats.state,
            "cpus": stats.cpus as Any, "cpuPercent": stats.cpuPercent as Any, "memoryUsedMb": stats.memoryUsedMb as Any,
            "memoryTotalMb": stats.memoryTotalMb as Any, "diskUsedMb": stats.diskUsedMb as Any, "diskTotalMb": stats.diskTotalMb as Any,
            "ipv4": machine.address?.ipv4 as Any, "desktop": machine.opensCarrierDesktop,
        ]
        if let cost = CloudCreationRows.cost(machine, limits: nil) {
            facts["cost"] = ["hourlyRateUsd": cost.hourlyRateUsd as Any, "runningSince": cost.runningSince?.timeIntervalSince1970 as Any,
                             "estimatedCostUsd": cost.estimatedCostUsd(now: now) as Any, "usage": cost.usage(now: now) as Any].compacted
        }
        if let idle = machine.idlePause {
            var pause: [String: Any] = ["minutes": idle.minutes, "lastCheckedAt": idle.lastCheckedAt as Any, "idleSince": idle.idleSince as Any,
                                        "lastApiActivityAt": idle.lastApiActivityAt as Any, "privateAddressKnown": idle.privateAddressKnown]
            if let decision = idle.lastDecision {
                pause["lastDecision"] = ["at": decision.at, "outcome": decision.outcome, "reason": decision.reason,
                                         "run": ["checked": decision.run.checked, "elapsedMs": decision.run.elapsedMs]]
            }
            facts["idlePause"] = pause.compacted
        }
        if let failure = machine.lastChangeFailure { facts["failure"] = ["code": failure.code, "message": failure.message] }
        let reply = CloudHandlerRules().ask("cloud_handler_status", ["status": facts.compacted])
        var fields: [String: ActionResultValue] = [:]
        if case .object(let object)? = reply?["fields"].map(CloudHandlerRules.result) { fields = object }
        return (reply?["text"] as? String ?? "\(machine.title) (\(session.machineID))", fields)
    }
}
