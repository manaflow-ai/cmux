import AppKit
import CmuxSettings
import Foundation

struct OpenRoutingModifierPolicy {
    nonisolated func shouldBypassCmuxOpenRouting(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.shift) else { return false }
        return flags.isDisjoint(with: [.control, .option])
    }
}

struct BrowserOpenRoutingPolicy {
    private let modifierPolicy: OpenRoutingModifierPolicy

    nonisolated init(modifierPolicy: OpenRoutingModifierPolicy = OpenRoutingModifierPolicy()) {
        self.modifierPolicy = modifierPolicy
    }

    nonisolated func shouldOpenInCmuxBrowser(
        settingEnabled: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        settingEnabled && !modifierPolicy.shouldBypassCmuxOpenRouting(modifierFlags: modifierFlags)
    }
}

enum CommandClickFileOpenRoute: Equatable {
    case cmux
    case defaultApplication
    case fallback
}

enum CommandClickFileOpenRouter {
    nonisolated static func route(
        path: String,
        modifierFlags: NSEvent.ModifierFlags,
        routeSettings: any FileRouteSettingsReading = FileRouteSettingsStore(defaults: .standard),
        modifierPolicy: OpenRoutingModifierPolicy = OpenRoutingModifierPolicy()
    ) -> CommandClickFileOpenRoute {
        let shouldRoute = routeSettings.shouldRouteMarkdown(path: path)
            || routeSettings.shouldRouteSupportedFile(path: path)
        guard shouldRoute else { return .fallback }
        if modifierPolicy.shouldBypassCmuxOpenRouting(modifierFlags: modifierFlags) {
            return .defaultApplication
        }
        return .cmux
    }

    nonisolated static func shouldRouteInCmux(path: String) -> Bool {
        route(path: path, modifierFlags: []) == .cmux
    }

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: .standard)
        if store.shouldRouteMarkdown(path: filePath),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
            return true
        }

        guard store.shouldRouteSupportedFile(path: filePath) else {
            return false
        }
        return workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: filePath) != nil
    }

    @MainActor
    @discardableResult
    static func openInDefaultApplication(filePath: String) -> Bool {
        openInDefaultApplication(fileURL: URL(fileURLWithPath: filePath))
    }

    @MainActor
    @discardableResult
    static func openInDefaultApplication(fileURL: URL) -> Bool {
        FileExternalOpenAction.openDefault(fileURL: fileURL)
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

    @MainActor
    @discardableResult
    static func deferredOpenFileIfRouted(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        filePath: String,
        modifierFlags: NSEvent.ModifierFlags,
        defaultApplicationURL: URL? = nil,
        fallback: (@MainActor @Sendable () -> Void)? = nil
    ) -> Bool {
        guard route(path: filePath, modifierFlags: modifierFlags) != .fallback else {
            return false
        }
        // Ghostty's open-url callback holds a runtime lock; split creation and
        // native app handoff both run after the callback returns.
        DispatchQueue.main.async {
            let resolvedRoute = route(path: filePath, modifierFlags: modifierFlags)
            let nativeFileURL = defaultApplicationURL ?? URL(fileURLWithPath: filePath)
            if resolvedRoute == .defaultApplication {
                if !openInDefaultApplication(fileURL: nativeFileURL) {
                    fallback?()
                }
                return
            }
            guard resolvedRoute == .cmux else {
                fallback?()
                return
            }

            let resolvedWorkspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: preferredWorkspaceId
            )?.workspace ?? workspace
            guard !resolvedWorkspace.isRemoteTerminalSurface(surfaceId) else {
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
        return true
    }

    @MainActor
    @discardableResult
    static func deferredOpenURLFileIfRouted(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        fileURL: URL,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        deferredOpenFileIfRouted(
            workspace: workspace,
            preferredWorkspaceId: preferredWorkspaceId,
            surfaceId: surfaceId,
            filePath: fileURL.path,
            modifierFlags: modifierFlags,
            defaultApplicationURL: fileURL,
            fallback: {
                NSWorkspace.shared.open(fileURL)
            }
        )
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
        let didRoute = deferredOpenFileIfRouted(
            workspace: workspace,
            preferredWorkspaceId: preferredWorkspaceId,
            surfaceId: surfaceId,
            filePath: filePath,
            modifierFlags: [],
            fallback: fallback
        )
        if !didRoute {
            fallback?()
        }
    }
}
