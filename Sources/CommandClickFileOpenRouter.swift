import AppKit
import CmuxSettings
import CmuxTerminalCore
import Foundation

enum CommandClickFileOpenRouter {
    nonisolated static func shouldRouteInCmux(
        path: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: defaults)
        return store.shouldRouteMarkdown(path: path)
            || store.shouldRouteSupportedFile(path: path)
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            fileReference: TerminalFileReference(path: filePath),
            defaults: defaults
        )
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        fileReference: TerminalFileReference,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let filePath = fileReference.path
        let store = FileRouteSettingsStore(defaults: defaults)
        if fileReference.line == nil,
           store.shouldRouteMarkdown(path: filePath),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
            return true
        }

        guard store.shouldRouteSupportedFile(path: filePath) else {
            return false
        }

        if fileReference.line == nil,
           TerminalHTMLFileBrowserAction(defaults: defaults).open(
            fileURL: URL(fileURLWithPath: filePath),
            sourcePanelId: sourcePanelId,
            container: workspace
        ) {
            return true
        }

        return workspace.openOrFocusFilePreviewSplit(
            from: sourcePanelId,
            filePath: filePath,
            line: fileReference.line,
            column: fileReference.column
        ) != nil
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
    /// via `DispatchQueue.main.async` and re-validates the workspace and path
    /// at dispatch time (TOCTOU). When routing fails, `fallback` is called so
    /// the caller can open the file externally.
    @MainActor
    static func deferredOpenFileInCmux(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        fileReference: TerminalFileReference,
        defaults: UserDefaults = .standard,
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
            guard shouldRouteInCmux(path: fileReference.path, defaults: defaults) else {
                fallback?()
                return
            }
            if openInCmux(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                fileReference: fileReference,
                defaults: defaults
            ) {
                return
            }
            fallback?()
        }
    }
}
