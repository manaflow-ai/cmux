import CmuxSettings
import Foundation

extension AppDelegate {
    @discardableResult
    func openArtifactPatch(
        _ file: ArtifactSidebarFileAccess.OpenedFile,
        for tabManager: TabManager?
    ) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace,
              let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path),
              let descriptor = file.duplicateForChildProcess() else {
            return false
        }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return launchDiffViewerProcess(
            cliURL: cliURL,
            socketPath: socketPath,
            cwd: workspace.resolvedWorkingDirectory() ?? file.sourceURL.deletingLastPathComponent().path,
            workspaceId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            useLastTurnSource: false,
            sessionId: nil,
            patchFileDescriptor: descriptor
        )
    }

    @discardableResult
    func openArtifactPatch(_ fileURL: URL, for tabManager: TabManager?) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace,
              let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            return false
        }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return launchDiffViewerProcess(
            cliURL: cliURL,
            socketPath: socketPath,
            cwd: workspace.resolvedWorkingDirectory() ?? fileURL.deletingLastPathComponent().path,
            workspaceId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            useLastTurnSource: false,
            sessionId: nil,
            patchFileURL: fileURL
        )
    }
}
