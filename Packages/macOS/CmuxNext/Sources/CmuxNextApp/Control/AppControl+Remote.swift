import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import CmuxNextRemote
import CmuxNextServer
import CmuxNextSidebar

// `remote.machines`: every SSH machine with its route, link state, daemon
// state, capability level and workspaces (qualified `<machine>:workspace:N`).
// A short main-actor read of observable state; no network. `machine.list {refresh?}` and
// `device.join_line {open?, mint?, name?}`: the Machines section's rows and Add Device's join line
// (CmuxNextServer MachineAutomation); `refresh` (default true) reads `cmux machine list` once first.
extension AppControl {
    func registerRemoteMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("remote.machines") { _ in
                if let refusal = ControlError.policyRefusal("remote.machines", disabled: services.registry.disabledFeatures) { throw refusal }
                let rows: [JSONValue] = services.machines.ssh.map { session in
                    let store = session.daemon.store
                    let compat = services.machines.compatibility(of: session.daemon)
                    let status = SidebarBridge.sshStatus(session, compatibility: compat)
                    let workspaces: [JSONValue] = store.workspaces.enumerated().map { index, workspace in
                        .object(["id": .string(workspace.id), "ref": .string("\(session.host.label):workspace:\(index + 1)"),
                                 "name": .string(workspace.displayName)])
                    }
                    return .object([
                        "id": .string(session.machineID),
                        "name": .string(session.host.label),
                        "destination": .string(session.host.destination.description),
                        "session": .string(session.host.session),
                        "remote_binary": .string(session.host.remoteBinary),
                        "status": .string(String(describing: status)),
                        "link": .string(String(describing: session.linkStatus)),
                        "detail": RemoteStrings.detail(session).map(JSONValue.string) ?? .null,
                        "connect_at_launch": .bool(session.autoConnect),
                        "session_id": compat?.sessionID.map(JSONValue.string) ?? .null,
                        "daemon_version": compat.map { .string($0.versionLabel) } ?? .null,
                        "compatibility": compat.map { .string($0.level.rawValue) } ?? .null,
                        "missing_features": .array((compat?.missingOptional ?? []).map(JSONValue.string)),
                        "workspaces": .array(workspaces),
                    ])
                }
                return .value(.object(["machines": .array(rows), "unavailable": services.ssh.unavailableReason.map(JSONValue.string) ?? .null]))
            },
            .async("machine.list") { [weak services] call in
                guard let services else { return .null }
                if call.params["refresh"]?.boolValue ?? true { await services.joinedMachines.refresh() }
                return await Self.machineRows(services)
            }.withDeadline(.fixed(AddDeviceCard.automationDeadline)),
            .async("device.join_line") { [weak services] call in
                guard let services else { return .null }
                return try await Self.joinLine(call.params, services)
            }.withDeadline(.fixed(AddDeviceCard.automationDeadline)),
        ])
    }

    @MainActor private static func joinLine(_ params: [String: JSONValue], _ services: AppServices) async throws -> JSONValue {
        if let refusal = ControlError.policyRefusal("device.join_line", disabled: services.registry.disabledFeatures) { throw refusal }
        return await services.addDevice.automationJoinLine(params, over: services.windows.active?.window)
    }

    @MainActor private static func machineRows(_ services: AppServices) -> JSONValue {
        let rows = MachineSectionRow.rows(services.machines, health: services.machineHealth, joined: services.joinedMachines), rules = SidebarBridgeRules()
        return ["machines": .array(rows.map { $0.automationJSON(linkState: rules.rowLink(connected: $0.isConnected, connecting: $0.isConnecting,
                                                                                         serverState: $0.serverState?.rawValue)?.rawValue) })]
    }
}
