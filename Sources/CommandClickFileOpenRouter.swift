import AppKit
import CmuxSettings
import Foundation

enum CommandClickFileOpenRouter {
    nonisolated static func shouldRouteInCmux(
        path: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: defaults)
        return TerminalHTMLFileBrowserAction.canOpenInBrowser(
            URL(fileURLWithPath: path),
            defaults: defaults
        ) || store.shouldRouteMarkdown(path: path)
            || store.shouldRouteSupportedFile(path: path)
    }

    /// Rechecks route settings after a bounded filesystem probe has already
    /// established that the candidate is a readable regular file.
    nonisolated static func shouldRouteResolvedFileInCmux(
        path: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: defaults)
        return TerminalHTMLFileBrowserAction.canOpenInBrowser(
            URL(fileURLWithPath: path),
            defaults: defaults
        ) || (store.markdownRouteEnabled && FileRouteSettingsStore.isMarkdownPath(path))
            || store.supportedFileRouteEnabled
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String,
        resolvedFileURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: defaults)
        if store.shouldRouteMarkdown(path: filePath),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
            return true
        }

        if let resolvedFileURL,
           TerminalHTMLFileBrowserAction(defaults: defaults).open(
            fileURL: URL(fileURLWithPath: filePath),
            resolvedFileURL: resolvedFileURL,
            sourcePanelId: sourcePanelId,
            container: workspace
        ) {
            return true
        }

        guard store.shouldRouteSupportedFile(path: filePath) else {
            return false
        }

        return workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: filePath) != nil
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
    /// Ghostty and deadlocks (https://github.com/manaflow-ai/cmux/issues/3370).
    /// This helper defers the split creation
    /// via `DispatchQueue.main.async` and re-validates the workspace and path
    /// at dispatch time (TOCTOU). When routing fails, `fallback` is called so
    /// the caller can open the file externally. `completion` fires afterward.
    @MainActor
    static func deferredOpenFileInCmux(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        filePath: String,
        defaults: UserDefaults = .standard,
        fallback: (@MainActor @Sendable () -> Void)? = nil,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let resolvedWorkspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: preferredWorkspaceId
            )?.workspace ?? workspace
            guard !resolvedWorkspace.isRemoteTerminalSurface(surfaceId) else {
                fallback?()
                completion?()
                return
            }
            guard shouldRouteInCmux(path: filePath, defaults: defaults) else {
                fallback?()
                completion?()
                return
            }
            if openInCmux(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                filePath: filePath,
                defaults: defaults
            ) {
                completion?()
                return
            }
            fallback?()
            completion?()
        }
    }
}
