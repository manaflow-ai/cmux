import CmuxNextControl
import CmuxNextSettings
import CmuxNextRemote

// `remote.machines`: every SSH machine with its route, link state, daemon
// state, capability level and workspaces (qualified `<machine>:workspace:N`).
// A short main-actor read of observable state; no network.
extension AppControl {
    func registerRemoteMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("remote.machines") { _ in
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
        ])
    }
}
