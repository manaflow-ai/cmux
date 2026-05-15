import Foundation

enum CommandClickFileOpenRouter {
    /// File extensions that should be rendered by the embedded browser
    /// rather than the file-preview viewer. Without this, opening a local
    /// `.html` file (cmd-click in terminal, file-explorer reveal, etc.)
    /// drops into the text-mode preview and shows the raw HTML source.
    static let browserRenderedExtensions: Set<String> = ["html", "htm", "xhtml"]

    static func shouldRenderInBrowser(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return browserRenderedExtensions.contains(ext)
    }

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
        // HTML-like documents are intended to be rendered, not read as
        // source. Route them into the embedded browser when the supported-
        // file routing toggle is on; fall back to the rest of the pipeline
        // (markdown viewer / file preview) otherwise.
        if shouldRenderInBrowser(path: filePath),
           CmdClickSupportedFileRouteSettings.isEnabled(),
           CmdClickSupportedFileRouteSettings.isReadableRegularFile(path: filePath) {
            let fileURL = URL(fileURLWithPath: filePath)
            if let targetPane = workspace.preferredRightSideTargetPane(fromPanelId: sourcePanelId),
               workspace.newBrowserSurface(inPane: targetPane, url: fileURL, focus: true) != nil {
                return true
            }
            if workspace.newBrowserSplit(
                from: sourcePanelId,
                orientation: .horizontal,
                url: fileURL
            ) != nil {
                return true
            }
            // Browser creation failed (e.g. browser disabled). Fall through
            // to the regular preview pipeline below so the click is not lost.
        }

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
