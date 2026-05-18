import Foundation

enum CommandClickFileOpenRouter {
    nonisolated static func shouldRouteInCmux(path: String) -> Bool {
        CmdClickMarkdownRouteSettings.shouldRoute(path: path)
            || CmdClickSupportedFileRouteSettings.shouldRoute(path: path)
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String
    ) -> Bool {
        if CmdClickMarkdownRouteSettings.shouldRoute(path: filePath),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
            return true
        }

        guard CmdClickSupportedFileRouteSettings.shouldRoute(path: filePath) else {
            return false
        }
        return workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: filePath) != nil
    }
}
