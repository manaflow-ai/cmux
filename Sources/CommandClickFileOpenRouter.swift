import AppKit
import CmuxSettings
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
        let store = FileRouteSettingsStore(defaults: defaults)
        if openConfiguredFileAction(workspace: workspace, filePath: filePath) {
            return true
        }

        if store.shouldRouteMarkdown(path: filePath),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
            return true
        }

        guard store.shouldRouteSupportedFile(path: filePath) else {
            return false
        }

        if TerminalHTMLFileBrowserAction(defaults: defaults).open(
            fileURL: URL(fileURLWithPath: filePath),
            sourcePanelId: sourcePanelId,
            container: workspace
        ) {
            return true
        }

        return workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: filePath) != nil
    }

    /// Returns whether the workspace has a config action claiming this path.
    @MainActor
    static func hasConfiguredFileHandler(workspace: Workspace, filePath: String) -> Bool {
        configuredFileAction(workspace: workspace, filePath: filePath) != nil
    }

    /// Executes a config-registered file handler using the workspace's
    /// window-scoped action registry and trust policy.
    @MainActor
    @discardableResult
    static func openConfiguredFileAction(workspace: Workspace, filePath: String) -> Bool {
        guard let context = configContext(for: workspace),
              let action = context.configStore.fileAction(for: filePath) else {
            return false
        }
        return CmuxConfigExecutor.executeFileAction(
            action: action,
            filePath: filePath,
            commands: context.configStore.loadedCommands,
            commandSourcePaths: context.configStore.commandSourcePaths,
            tabManager: context.tabManager,
            baseCwd: workspace.currentDirectory,
            globalConfigPath: context.configStore.globalConfigPath,
            presentingWindow: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id)
        )
    }

    @MainActor
    private static func configuredFileAction(
        workspace: Workspace,
        filePath: String
    ) -> CmuxResolvedConfigAction? {
        configContext(for: workspace)?.configStore.fileAction(for: filePath)
    }

    @MainActor
    private static func configContext(
        for workspace: Workspace
    ) -> (tabManager: TabManager, configStore: CmuxConfigStore)? {
        guard let app = AppDelegate.shared else { return nil }
        guard let context = app.mainWindowContexts.values.first(where: { context in
            context.tabManager.workspacesById[workspace.id] === workspace
        }), let configStore = context.cmuxConfigStore else { return nil }
        return (context.tabManager, configStore)
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
        filePath: String,
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
            guard shouldRouteInCmux(path: filePath, defaults: defaults)
                || hasConfiguredFileHandler(workspace: resolvedWorkspace, filePath: filePath) else {
                fallback?()
                return
            }
            if openInCmux(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                filePath: filePath,
                defaults: defaults
            ) {
                return
            }
            fallback?()
        }
    }
}
