import CmuxMobileShellModel
import Foundation

@MainActor
extension WorkspaceShellView {
    func openTerminalFromSurfaceGrid(
        _ workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        surfaceGridTerminalOpenTask?.cancel()
        let requestID = UUID()
        surfaceGridTerminalOpenRequestID = requestID
        surfaceGridTerminalOpenTask = Task { @MainActor in
            defer {
                if surfaceGridTerminalOpenRequestID == requestID {
                    surfaceGridTerminalOpenTask = nil
                    surfaceGridTerminalOpenRequestID = nil
                }
            }
            guard let resolvedWorkspaceID = await WorkspaceTerminalSurfaceSelection(
                store: store,
                browserStore: browserStore
            ).selectFromSurfaceGrid(
                workspaceID: workspaceID,
                terminalID: terminalID
            ), !Task.isCancelled,
               surfaceGridTerminalOpenRequestID == requestID else { return }
            compactLocalBrowserWorkspaceID = nil
            compactNavigationPath = [resolvedWorkspaceID]
        }
    }
}
