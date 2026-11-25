import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextImportCards

extension AppServices: ConductorImportHost {
    var conductorDaemon: DaemonConnection? { daemon.connection }
    func conductorWorkspaceKey(_ id: String) -> WorkspaceKey? { daemon.store.workspace(id: id)?.key }
    func openConductorWorkspace(folder: String, name: String, key: WorkspaceKey) async throws -> String { try await windows.createWorkspace(WorkspaceSpawn(cwd: folder, name: name, key: key)) }
}
