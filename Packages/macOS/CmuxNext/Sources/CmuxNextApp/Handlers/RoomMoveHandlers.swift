import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Moving and duplicating workspaces and groups between rooms. A moved
/// workspace keeps its terminals and live pages (each browser tab stays in
/// its browser profile, data-model.md 5); the window that shows it keeps
/// owning it, so it appears there again when that window shows the target
/// room.
enum RoomMoveHandlers {
    typealias Bind = (ActionID, @escaping @MainActor (ActionInvocation) throws -> Void) -> Void

    static func bind(_ bind: Bind, context: AppActionContext) {
        bind("workspace.moveToRoom") { invocation in
            guard let room = try context.optionalRoom(invocation["room"]) else {
                throw ActionFailure.invalidTarget(RoomStrings.roomArgumentRequired)
            }
            let (workspace, key) = try context.workspace(invocation)
            let machines = context.services.machines
            guard let qualified = WindowProfiles.qualified(workspace.id, machines: machines) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
            }
            if let membership = WindowProfiles.membership(machines), membership.pins[qualified] == room.id {
                throw ActionFailure.invalidTarget(RoomStrings.alreadyInRoom)
            }
            // A move is a pin in the home session: the workspace's own
            // daemon is not written (data-model.md 1.2c, 3.2).
            let target = room.id, session = qualified.session
            machines.local.send("pin-workspace") { try await $0.pinWorkspace(session: session, key: key, to: target) }
        }
        bind("workspace.duplicateToRoom") { invocation in
            guard let room = try context.optionalRoom(invocation["room"]) else {
                throw ActionFailure.invalidTarget(RoomStrings.roomArgumentRequired)
            }
            let (workspace, _) = try context.workspace(invocation)
            duplicate(workspace, into: room.id, context)
        }
        bind("workspaceGroup.moveToRoom") { invocation in
            guard let room = try context.optionalRoom(invocation["room"]) else {
                throw ActionFailure.invalidTarget(RoomStrings.roomArgumentRequired)
            }
            let group = try context.personalGroup(invocation)
            let id = group.id, target = room.id
            context.services.machines.local.send("update-personal-group") { try await $0.updatePersonalGroup(id, room: target) }
        }
    }

    private static func daemon(of workspace: WorkspaceModel, _ context: AppActionContext) -> DaemonService {
        context.services.machines.daemon(forWorkspace: workspace.id) ?? context.services.machines.local
    }

    /// The directories a duplicate restarts, one per terminal tab in
    /// screen, pane and tab order.
    static func terminalDirectories(of workspace: WorkspaceModel) -> [String?] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty }.map(\.cwd)
    }

    /// A new workspace in `room` with the same name and one new terminal
    /// per terminal tab of `workspace`, each in that tab's directory. A
    /// duplicate never shares a running terminal. It is shown in the active
    /// window, which switches to `room`.
    private static func duplicate(_ workspace: WorkspaceModel, into room: ProfileID, _ context: AppActionContext) {
        let windows = context.services.windows!
        let directories = terminalDirectories(of: workspace)
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        let spawn = WorkspaceSpawn(cwd: directories.first ?? nil, name: workspace.displayName, profile: room)
        let daemon = daemon(of: workspace, context)
        context.services.registry.track(Task {
            do {
                let id = try await windows.createWorkspace(spawn, on: daemon, into: target)
                guard let connection = daemon.connection, directories.count > 1 else { return nil }
                for cwd in directories.dropFirst() {
                    _ = try await connection.createTerminal(in: WorkspaceKey(rawValue: id), cwd: cwd ?? nil)
                }
                return nil
            } catch {
                return ActionWorkFailure("workspace.duplicateToRoom", error)
            }
        })
    }
}
