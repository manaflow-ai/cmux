import AppKit
import CmuxSettings
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

enum CommandClickFileOpenRouter {
    nonisolated static func shouldRouteInCmux(path: String) -> Bool {
        let store = FileRouteSettingsStore(defaults: .standard)
        return store.shouldRouteMarkdown(path: path)
            || store.shouldRouteSupportedFile(path: path)
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        resolution: TerminalPathResolution
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: .standard)
        if store.shouldRouteMarkdown(path: resolution.path),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: resolution.path) != nil {
            return true
        }

        guard store.shouldRouteSupportedFile(path: resolution.path) else {
            return false
        }
        return workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: resolution.path) != nil
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

    /// Build the shared path-resolution context for a terminal surface.
    ///
    /// The live per-panel directory remains authoritative. If output predates
    /// a cwd change, resolution falls back to the tracked repository root and
    /// then the workspace directory; the resolver still requires existence at
    /// every candidate.
    @MainActor
    static func resolvePathContext(
        workspace: Workspace,
        surfaceId: UUID
    ) -> TerminalPathResolutionContext {
        let workingDirectory = resolveWorkingDirectory(
            workspace: workspace,
            surfaceId: surfaceId
        )
        let standardizedWorkingDirectory = workingDirectory.map {
            ($0 as NSString).standardizingPath
        }
        let fallbackDirectories = [
            workspace.extensionSidebarProjectRootPath,
            workspace.terminalPanel(for: surfaceId)?.requestedWorkingDirectory,
            workspace.currentDirectory,
        ].compactMap { directory -> String? in
            guard let directory else { return nil }
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let standardized = (trimmed as NSString).standardizingPath
            guard let standardizedWorkingDirectory else { return standardized }
            guard standardizedWorkingDirectory == standardized ||
                    standardizedWorkingDirectory.hasPrefix(standardized + "/") else {
                return nil
            }
            return standardized
        }
        return TerminalPathResolutionContext(
            workingDirectory: workingDirectory,
            fallbackDirectories: fallbackDirectories
        )
    }

    /// Open a resolved file outside cmux while preserving source locations.
    ///
    /// The Ghostty callback keeps the historical system opener for ordinary
    /// absolute paths. A source location necessarily uses the preferred-editor
    /// path so commands that understand `file:line[:column]` can honor it.
    @MainActor
    @discardableResult
    static func openExternally(
        _ resolution: TerminalPathResolution,
        preferConfiguredEditor: Bool
    ) -> Bool {
        let fileURL = URL(fileURLWithPath: resolution.path)
        guard preferConfiguredEditor || resolution.line != nil else {
            return NSWorkspace.shared.open(fileURL)
        }
        PreferredEditorService(defaults: .standard).open(
            fileURL,
            line: resolution.line,
            column: resolution.column
        )
        return true
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
        resolution: TerminalPathResolution,
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
            guard shouldRouteInCmux(path: resolution.path) else {
                fallback?()
                return
            }
            if openInCmux(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                resolution: resolution
            ) {
                return
            }
            fallback?()
        }
    }
}
