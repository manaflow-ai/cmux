import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// The Cloud toggle (#26062): with `cloud.newWorkspacesInCloud` on, a person's New Workspace runs
/// on a new Cloud machine of its own instead of this Mac, the way a Codex or ChatGPT Work cloud task
/// gets its own VM. It is the New Cloud Workspace flow (``CloudCreationFlow``: the window shows each
/// step at once, a failure stays with Retry), always with a new machine, whose first workspace
/// opens in the person's folder copied there (`cmux link sync push`, as Move to Cloud copies a
/// chat's folder) or in the machine's empty folder (`cloud.newWorkspaceFolder`). Agent chats
/// started in that workspace run on its machine.
@MainActor
struct CloudNewWorkspace {
    let context: AppActionContext

    /// The plan for a New Workspace `invocation` whose person works in `cwd`; nil keeps it on this
    /// Mac: the toggle is off, a script or agent asked (only a person's gesture follows it), or it
    /// names a machine.
    static func plan(_ invocation: ActionInvocation, cwd: String?, settings root: CmuxNextSettings.JSONValue?) -> CloudNewWorkspacePlan? {
        guard invocation.origin == .user, let root else { return nil }
        let setting = CloudNewWorkspaceSetting()
        return CloudNewWorkspacePlan(inCloud: setting.inCloud(in: root), inheritsFolder: setting.folder(in: root) == .inherit,
                                     cwd: cwd, namesMachine: invocation["machine"] != nil)
    }

    /// Starts the new machine and shows its progress in `window` in this turn.
    func start(_ plan: CloudNewWorkspacePlan, in window: WindowState?) {
        let services = context.services
        let flow = CloudHandlers.creationFlow(context, startedByPerson: true) { session in
            defer { RemoteGroupHandlers.mark(session: session.daemon.store.registryID) } // one group per Cloud machine
            return try await Self.open(plan, on: session, services: services)
        }
        flow.start(in: window, existing: nil)
    }

    /// The machine's workspace for `plan`: the folder copied first, then a workspace whose terminal
    /// starts in it (in the machine's home for an empty one). Returns the workspace's id.
    static func open(_ plan: CloudNewWorkspacePlan, on session: CloudMachineSession, services: AppServices) async throws -> String {
        let name = session.machine.title
        guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudMoveStrings.notConnected(name)) }
        var cwd: String?
        if let folder = plan.folder {
            // The app server link's socket serves one connection, the app's own: the sync CLI needs another.
            guard session.appLink == nil else { throw ActionFailure(message: CloudMoveStrings.linkUnsupported(name)) }
            guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
            guard let socket = await connection.endpoint?.socketPath else { throw ActionFailure(message: CloudMoveStrings.notConnected(name)) }
            let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
            cwd = try await sync(folder, socket: socket, machine: name, workRoots: services.cloud.move.workRoots) {
                try await cli.syncPush(socket: $0, local: $1, remote: $2)
            }.chat
        }
        let key = WorkspaceKey.generate()
        try await WorkspaceCreation.createWithFirstTab(key, name: plan.workspaceName, on: connection, repair: session.emptyWorkspaces) { result in
            _ = try await connection.createTerminal(in: result.key, cwd: cwd)
        }
        return key.rawValue
    }

    /// Copies `folder` under the first of `workRoots` the machine lets it write (an image without the
    /// work user refuses its home with `fs.permission_denied`), through `push(socket, local, remote)`.
    /// Returns the copied folder and the person's folder in it, on the machine.
    static func sync(_ folder: CloudMoveFolder, socket: String, machine: String, workRoots: [String],
                     push: (String, String, String) async throws -> CloudMoveCLI.Answer) async throws -> (folder: String, chat: String) {
        var last = CloudMoveCLI.Answer(ok: false)
        for root in workRoots {
            let remote = folder.remote(under: root)
            last = try await push(socket, folder.root, remote.folder)
            if last.ok { return remote }
            guard last.errorCode == "fs.permission_denied" else { break }
        }
        if last.errorCode == CloudMoveStrings.outdatedCode { throw ActionFailure(message: CloudMoveStrings.outdatedMachine(machine)) }
        throw ActionFailure(message: CloudMoveStrings.syncFailed(machine, last.error ?? last.errorCode ?? ""))
    }
}
