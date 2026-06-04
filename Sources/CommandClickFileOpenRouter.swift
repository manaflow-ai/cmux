import AppKit
import Foundation

enum CommandClickFileRouteKind: Sendable {
    case markdown
    case supportedFile
}

enum CommandClickFileOpenRouter {
    nonisolated static func routeKind(path: String) -> CommandClickFileRouteKind? {
        if CmdClickMarkdownRouteSettings.shouldRoute(path: path) {
            return .markdown
        }
        if CmdClickSupportedFileRouteSettings.shouldRoute(path: path) {
            return .supportedFile
        }
        return nil
    }

    nonisolated static func shouldRouteInCmux(path: String) -> Bool {
        routeKind(path: path) != nil
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String
    ) -> Bool {
        guard let routeKind = routeKind(path: filePath) else { return false }
        return openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: filePath,
            routeKind: routeKind
        )
    }

    @MainActor
    private static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String,
        routeKind: CommandClickFileRouteKind
    ) -> Bool {
        switch routeKind {
        case .markdown:
            if workspace.openOrFocusMarkdownSplit(
                from: sourcePanelId,
                filePath: filePath
            ) != nil {
                return true
            }
            guard CmdClickSupportedFileRouteSettings.shouldRoute(path: filePath) else {
                return false
            }
            return workspace.openOrFocusFilePreviewSplit(
                from: sourcePanelId,
                filePath: filePath
            ) != nil
        case .supportedFile:
            return workspace.openOrFocusFilePreviewSplit(
                from: sourcePanelId,
                filePath: filePath
            ) != nil
        }
    }

    /// Resolve the working directory for a terminal surface, preferring the
    /// per-panel directory, then the panel's requested working directory,
    /// then the workspace-level directory.
    @MainActor
    static func resolveWorkingDirectory(
        workspace: Workspace,
        surfaceId: UUID
    ) -> String? {
        if let dir = workspace.panelDirectories[surfaceId]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        if let dir = workspace.terminalPanel(for: surfaceId)?
            .requestedWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        let dir = workspace.currentDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    /// Schedule a file open in cmux, deferred to the next runloop tick.
    ///
    /// Ghostty's `Surface.openUrl` holds an internal `os_unfair_lock` when it
    /// dispatches into Swift; opening a new panel synchronously re-enters
    /// Ghostty and deadlocks (#3370). This helper defers the split creation
    /// via a main-actor task and re-validates the route off-main before the UI
    /// mutation. When routing fails, `fallback` is called so the caller can
    /// open the file externally.
    @MainActor
    static func deferredOpenFileInCmux(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        filePath: String,
        fallback: (@MainActor @Sendable () -> Void)? = nil
    ) {
        Task { @MainActor [workspace, preferredWorkspaceId, surfaceId, filePath, fallback] in
            let routeKind = await Task.detached(priority: .userInitiated) {
                Self.routeKind(path: filePath)
            }.value
            let resolvedWorkspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: preferredWorkspaceId
            )?.workspace ?? workspace
            guard !resolvedWorkspace.isRemoteTerminalSurface(surfaceId) else {
                fallback?()
                return
            }
            guard let routeKind else {
                fallback?()
                return
            }
            if openInCmux(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                filePath: filePath,
                routeKind: routeKind
            ) {
                return
            }
            fallback?()
        }
    }
}
