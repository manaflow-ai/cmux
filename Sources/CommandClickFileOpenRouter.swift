import AppKit
import Bonsplit
import CmuxSettings
import Foundation

enum CommandClickFileOpenRouter {
    nonisolated static func shouldRouteInCmux(path: String) -> Bool {
        let store = FileRouteSettingsStore(defaults: .standard)
        return store.shouldRouteMarkdown(path: path)
            || store.shouldRouteSupportedFile(path: path)
    }

    /// The most recent cmd-click HTML→browser open, keyed by workspace + path,
    /// used to collapse the two cmd-click routing paths — the mouse handler and
    /// Ghostty's OPEN_URL action, both of which reach `openInCmux` for one
    /// physical click — into a single browser tab.
    ///
    /// Interim: unlike `openOrFocus*Split`, `newBrowserSplit` doesn't dedupe,
    /// and `BrowserPanel` carries no stable local-file identity to match on (its
    /// `currentURL` drifts to WebKit-normalized values after navigation), so a
    /// panel-scan open-or-focus isn't reliable here today. Remove this once a
    /// browser surface has a stable local-file key (cf. #7413) and route through
    /// an idempotent open-or-focus primitive. Keyed by workspace so the same
    /// path opened in another workspace within the window isn't swallowed; the
    /// 1s window only needs to absorb the two dispatches of one click.
    @MainActor private static var recentBrowserOpen: (workspaceId: UUID, path: String, at: Date)?
    private static let browserOpenDedupeWindow: TimeInterval = 1.0

    @MainActor
    static func openInCmux(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: .standard)

        // Local HTML renders in the embedded browser (a rendered page), not the
        // raw-source preview. Gated by the same toggle + readable-regular-file
        // discipline as the other routed files (via `shouldRouteSupportedFile`)
        // so an opt-out — or a missing / non-regular path — falls through to the
        // external opener instead of a broken embedded tab.
        if FileRouteSettingsStore.isHTMLPath(filePath),
           store.shouldRouteSupportedFile(path: filePath),
           BrowserAvailabilitySettings.isEnabled() {
            // The same path can arrive from both cmd-click routes for one click;
            // see `recentBrowserOpen` for why this window collapses the second
            // into a no-op instead of opening a duplicate tab.
            let now = Date()
            if let recent = recentBrowserOpen,
               recent.workspaceId == workspace.id,
               recent.path == filePath,
               now.timeIntervalSince(recent.at) < browserOpenDedupeWindow {
                return true
            }
            if workspace.newBrowserSplit(
                from: sourcePanelId,
                orientation: .horizontal,
                url: URL(fileURLWithPath: filePath)
            ) != nil {
                recentBrowserOpen = (workspaceId: workspace.id, path: filePath, at: now)
                return true
            }
            // Browser is on but the split couldn't be created (e.g. a remote
            // tmux mirror has no local browser surface): open externally rather
            // than dumping raw HTML source into a preview pane.
            return false
        }

        if store.shouldRouteMarkdown(path: filePath),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
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
