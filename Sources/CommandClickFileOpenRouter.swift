import AppKit
import CmuxSettings
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

/// Coordinates command-click file routing with injected settings and opener dependencies.
@MainActor
struct CommandClickFileOpenRouter {
    private let routeSettings: any FileRouteSettingsReading
    private let supportsExternalLocations: @MainActor @Sendable () -> Bool
    private let openExternal: @MainActor @Sendable (URL, Int?, Int?) -> Void

    init(
        routeSettings: any FileRouteSettingsReading,
        supportsExternalLocations: @escaping @MainActor @Sendable () -> Bool,
        openExternal: @escaping @MainActor @Sendable (URL, Int?, Int?) -> Void
    ) {
        self.routeSettings = routeSettings
        self.supportsExternalLocations = supportsExternalLocations
        self.openExternal = openExternal
    }

    init(defaults: UserDefaults) {
        let externalOpener = PreferredEditorService(defaults: defaults)
        self.init(
            routeSettings: FileRouteSettingsStore(defaults: defaults),
            supportsExternalLocations: { externalOpener.supportsSourceLocations },
            openExternal: { url, line, column in
                externalOpener.open(url, line: line, column: column)
            }
        )
    }

    func shouldRouteInCmux(resolution: TerminalPathResolution) -> Bool {
        if resolution.line != nil, supportsExternalLocations() {
            return false
        }
        return routeSettings.shouldRouteMarkdown(path: resolution.path)
            || routeSettings.shouldRouteSupportedFile(path: resolution.path)
    }

    @MainActor
    func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        resolution: TerminalPathResolution
    ) -> Bool {
        guard shouldRouteInCmux(resolution: resolution) else { return false }
        if routeSettings.shouldRouteMarkdown(path: resolution.path),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: resolution.path) != nil {
            return true
        }

        guard routeSettings.shouldRouteSupportedFile(path: resolution.path) else {
            return false
        }
        return workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: resolution.path) != nil
    }

    /// Resolve the working directory for a terminal surface, preferring the
    /// per-panel directory, then the panel's requested working directory,
    /// then the workspace-level directory.
    @MainActor
    private func resolveWorkingDirectory(
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
    func resolvePathContext(
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
    func openExternally(
        _ resolution: TerminalPathResolution,
        preferConfiguredEditor: Bool
    ) -> Bool {
        let fileURL = URL(fileURLWithPath: resolution.path)
        guard preferConfiguredEditor || resolution.line != nil else {
            return NSWorkspace.shared.open(fileURL)
        }
        openExternal(
            fileURL,
            resolution.line,
            resolution.column
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
    func deferredOpenFileInCmux(
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
            guard shouldRouteInCmux(resolution: resolution) else {
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
