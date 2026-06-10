import AppKit
import Foundation

enum CommandClickFileOpenRouter {
    nonisolated static func shouldRouteInCmux(path: String) -> Bool {
        CmdClickTerminalEditorRouteSettings.shouldRoute(path: path)
            || CmdClickMarkdownRouteSettings.shouldRoute(path: path)
            || CmdClickSupportedFileRouteSettings.shouldRoute(path: path)
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String
    ) -> Bool {
        // Checked first: an extension listed in `terminalEditorExtensions` is an
        // explicit user override that wins over the markdown/file-preview routes
        // (so listing "md" opens nvim instead of the markdown viewer). The route
        // is inert until the user lists extensions, so defaults are unchanged.
        if CmdClickTerminalEditorRouteSettings.shouldRoute(path: filePath),
           workspace.openTerminalEditorTab(from: sourcePanelId, filePath: filePath) != nil {
            return true
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

    /// Resolve the working directory for a terminal surface, preferring the
    /// per-panel directory, then the panel's requested working directory,
    /// then the workspace-level directory. Delegates to the shared
    /// `Workspace.resolvedTerminalWorkingDirectory(forPanelId:)` so the
    /// command-click router and the terminal-editor opener stay in sync.
    @MainActor
    static func resolveWorkingDirectory(
        workspace: Workspace,
        surfaceId: UUID
    ) -> String? {
        workspace.resolvedTerminalWorkingDirectory(forPanelId: surfaceId)
    }

    /// Schedule a file open in cmux, deferred to the next runloop tick.
    ///
    /// Ghostty's `Surface.openUrl` holds an internal `os_unfair_lock` when it
    /// dispatches into Swift; opening a new panel synchronously re-enters
    /// Ghostty and deadlocks (#3370). This helper defers the split creation
    /// via `DispatchQueue.main.async` and re-validates the workspace and path
    /// at dispatch time (TOCTOU). When routing fails, `fallback` is called so
    /// the caller can open the file externally.
    @MainActor
    static func deferredOpenFileInCmux(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        filePath: String,
        fallback: (@MainActor @Sendable () -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let resolvedWorkspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: preferredWorkspaceId
            )?.workspace ?? workspace
            guard !resolvedWorkspace.isRemoteTerminalSurface(surfaceId) else {
                fallback?()
                return
            }
            guard shouldRouteInCmux(path: filePath) else {
                fallback?()
                return
            }
            if openInCmux(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                filePath: filePath
            ) {
                return
            }
            fallback?()
        }
    }
}
