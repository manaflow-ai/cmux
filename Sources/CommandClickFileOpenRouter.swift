import AppKit
import CmuxSettings
import Foundation

enum CommandClickFileOpenRouter {
    enum Fallback {
        case preferredEditor
        case systemDefault

        @MainActor
        func open(_ url: URL) {
            switch self {
            case .preferredEditor:
                PreferredEditorSettings.open(url)
            case .systemDefault:
                NSWorkspace.shared.open(url)
            }
        }
    }

    private enum Action {
        case markdownViewer
        case cmuxPreview
        case cmuxBrowser
        case preferredEditor
        case systemDefault
        case unhandled

        var routesInCmux: Bool {
            switch self {
            case .markdownViewer, .cmuxPreview, .cmuxBrowser:
                return true
            case .preferredEditor, .systemDefault, .unhandled:
                return false
            }
        }

        var handlesCommandClick: Bool {
            self != .unhandled
        }
    }

    nonisolated static func shouldRouteInCmux(path: String, defaults: UserDefaults = .standard) -> Bool {
        action(for: path, defaults: defaults).routesInCmux
    }

    nonisolated static func shouldHandleCommandClick(path: String, defaults: UserDefaults = .standard) -> Bool {
        action(for: path, defaults: defaults).handlesCommandClick
    }

    private nonisolated static func action(for path: String, defaults: UserDefaults) -> Action {
        if let behavior = FileExtensionOpenBehaviorSettings.behavior(forPath: path, defaults: defaults) {
            switch behavior {
            case .automatic:
                break
            case .cmuxPreview:
                return CmdClickSupportedFileRouteSettings.isReadableRegularFile(path: path) ? .cmuxPreview : .unhandled
            case .markdownViewer:
                return CmdClickSupportedFileRouteSettings.isReadableRegularFile(path: path) ? .markdownViewer : .unhandled
            case .cmuxBrowser:
                return CmdClickSupportedFileRouteSettings.isReadableRegularFile(path: path) ? .cmuxBrowser : .unhandled
            case .preferredEditor:
                return .preferredEditor
            case .systemDefault:
                return .systemDefault
            }
        }

        if CmdClickMarkdownRouteSettings.shouldRoute(path: path, defaults: defaults) {
            return .markdownViewer
        }
        if CmdClickSupportedFileRouteSettings.shouldRoute(path: path, defaults: defaults) {
            return .cmuxPreview
        }
        return .unhandled
    }

    @MainActor
    static func openCommandClickFile(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String,
        fallback: Fallback
    ) -> Bool {
        let fileURL = URL(fileURLWithPath: filePath)
        switch action(for: filePath, defaults: .standard) {
        case .markdownViewer:
            if workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
                return true
            }
            fallback.open(fileURL)
            return true
        case .cmuxPreview:
            if workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: filePath) != nil {
                return true
            }
            fallback.open(fileURL)
            return true
        case .cmuxBrowser:
            if workspace.openOrFocusBrowserSplit(from: sourcePanelId, url: fileURL) != nil {
                return true
            }
            fallback.open(fileURL)
            return true
        case .preferredEditor:
            PreferredEditorSettings.open(fileURL)
            return true
        case .systemDefault:
            NSWorkspace.shared.open(fileURL)
            return true
        case .unhandled:
            return false
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

    /// Defers command-click routing until Ghostty's mouse callback has unwound.
    ///
    /// Ghostty's `Surface.openUrl` holds an internal lock when it dispatches into
    /// Swift; opening a new panel synchronously re-enters Ghostty and can
    /// deadlock. The deferred task re-validates the workspace and falls back
    /// externally when cmux does not handle the file.
    @MainActor
    static func deferredOpenCommandClickFile(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        filePath: String,
        fallback: Fallback
    ) {
        Task { @MainActor in
            let resolvedWorkspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: preferredWorkspaceId
            )?.workspace ?? workspace
            guard !resolvedWorkspace.isRemoteTerminalSurface(surfaceId) else {
                fallback.open(URL(fileURLWithPath: filePath))
                return
            }
            guard openCommandClickFile(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                filePath: filePath,
                fallback: fallback
            ) else {
                fallback.open(URL(fileURLWithPath: filePath))
                return
            }
        }
    }
}
