import AppKit
import CmuxTerminal

extension AppDelegate.MainWindowContext {
    /// The Dock for this window, created on first access and retained through
    /// context replacement. Session restore wins; otherwise global config seeds it.
    func windowDockStore(notificationStore: TerminalNotificationStore?) -> DockSplitStore {
        if let existing = windowDock {
            existing.notificationStore = notificationStore
            return existing
        }
        let store = tabManager.makeWindowDockStore(windowId: windowId)
        store.notificationStore = notificationStore
        windowDock = store
        workspaceTerminalFontSizeCoordinator.attachWindowDock(store)
        return store
    }

    func existingWindowDock() -> DockSplitStore? {
        windowDock
    }

    /// Detaches the live Dock while SwiftUI replaces this context's NSWindow.
    /// The recoverable route becomes its lifecycle owner until registration
    /// adopts it or an authoritative close retires it.
    func detachWindowDockForContextReplacement() -> DockSplitStore? {
        guard let dock = windowDock else { return nil }
        workspaceTerminalFontSizeCoordinator.detachWindowDock()
        windowDock = nil
        return dock
    }

    func adoptRecoveredWindowDock(_ dock: DockSplitStore) {
        guard !dock.isRetired else { return }
        if let existing = windowDock, existing !== dock {
            dock.retire()
            return
        }
        windowDock = dock
        workspaceTerminalFontSizeCoordinator.attachWindowDock(dock)
    }

    func restoreWindowDockSessionSnapshot(
        _ snapshot: SessionWindowSnapshot?,
        notificationStore: TerminalNotificationStore?,
        excludingStableIdentities: Set<UUID> = []
    ) {
        let promptBatch = SurfaceResumeRunPromptBatch.shared
        promptBatch.beginRestorePass()
        defer { promptBatch.endRestorePass() }

        guard let dockSnapshot = snapshot?.dock, let tabManagerSnapshot = snapshot?.tabManager else { return }
        windowDockStore(notificationStore: notificationStore).restoreSessionSnapshot(
            dockSnapshot,
            excludingStableIdentities: excludingStableIdentities,
            sourceWorkspaceResolver: { [tabManager] originalId in
                tabManager.restoredSessionWorkspace(
                    originalId: originalId,
                    from: tabManagerSnapshot
                )
            }
        )
    }

    func windowDockSessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex?,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    ) -> SessionSplitContainerSnapshot? {
        existingWindowDock()?.sessionSnapshot(
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        )
    }

    /// Tears down this context's Dock, closing any live terminals/browsers and
    /// their portals, so no Dock panel outlives its window.
    func teardownWindowDock() {
        workspaceTerminalFontSizeCoordinator.cancelWindowOwnedWork()
        guard let dock = windowDock else { return }
        windowDock = nil
        dock.retire()
    }
}

/// Per-window Docks.
///
/// Every main window hosts its own independent `DockSplitStore`: a window's
/// right-sidebar Dock panel mounts that window's store, created lazily the
/// first time the window shows the Dock. Session state restores it when present;
/// otherwise `~/.config/cmux/dock.json` seeds it. A transient SwiftUI context
/// replacement transfers the Dock through the recoverable route; an
/// authoritative close retires it so no PTYs outlive their window.
///
/// Each store's `workspaceId` IS the owning window's `windowId`. That keeps the
/// registry a plain dictionary lookup and makes Dock-scoped CLI results
/// (`workspace_id`) self-describing: they name the window whose Dock they hit.

extension AppDelegate {
    func restoreWindowDockSessionSnapshot(
        forWindowId windowId: UUID,
        from snapshot: SessionWindowSnapshot?,
        excludingStableIdentities: Set<UUID>
    ) {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?
            .restoreWindowDockSessionSnapshot(
                snapshot,
                notificationStore: notificationStore,
                excludingStableIdentities: excludingStableIdentities
            )
    }

    /// Legacy Dock routing alias, kept for CLI compatibility with the retired
    /// app-wide Global Dock. A `workspace_id` equal to this constant means "the
    /// Dock" generically and resolves to the Dock of whichever window the rest
    /// of the routing selects (explicit `window_id`, else the caller's window).
    /// Nonisolated so socket routing can compare ids off the main actor.
    nonisolated static let windowDockAliasWorkspaceId = UUID(uuidString: "D0CCD0CC-0000-4000-8000-000000000001")!

    /// Whether `id` routes to a per-window Dock: either the legacy alias or the
    /// owner id (== window id) of a registered main window, even if that window's
    /// Dock store has not been lazily created yet, or of a recoverable route
    /// retaining an existing Dock during context replacement.
    static func isWindowDockRoutingId(_ id: UUID) -> Bool {
        if id == windowDockAliasWorkspaceId { return true }
        guard let appDelegate = AppDelegate.shared else { return false }
        return appDelegate.mainWindowContext(forWindowId: id) != nil
            || appDelegate.existingWindowDock(forWindowId: id) != nil
    }

    private func mainWindowContext(forWindowId windowId: UUID) -> MainWindowContext? {
        mainWindowContexts.values.first { $0.windowId == windowId }
    }

    /// The Dock for the registered window `windowId`, created on first access.
    func windowDock(forWindowId windowId: UUID) -> DockSplitStore {
        guard let context = mainWindowContext(forWindowId: windowId) else {
            preconditionFailure("Window Dock requested for an unregistered main window")
        }
        return context.windowDockStore(notificationStore: notificationStore)
    }

    /// The Dock for a registered window-owner id, created on first access. `nil`
    /// means `windowId` is not a live window-Dock owner.
    func windowDockForRegisteredOwner(_ windowId: UUID) -> DockSplitStore? {
        mainWindowContext(forWindowId: windowId)?.windowDockStore(notificationStore: notificationStore)
    }

    /// The Dock of `tabManager`'s window, created on first access for a live
    /// registered window. A recoverable route never seeds a NEW Dock, but its
    /// transferred existing store remains addressable during context replacement.
    func windowDock(for tabManager: TabManager) -> DockSplitStore? {
        if let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) {
            return context.windowDockStore(notificationStore: notificationStore)
        }
        guard let windowId = windowId(for: tabManager) else { return nil }
        return existingWindowDock(forWindowId: windowId)
    }

    /// The window's Dock if it already exists, without creating it.
    func existingWindowDock(forWindowId windowId: UUID) -> DockSplitStore? {
        if let dock = mainWindowContext(forWindowId: windowId)?.existingWindowDock() {
            return dock
        }
        return recoverableMainWindowRoute(windowId: windowId)?.windowDock
    }

    /// The `TabManager` owning the window Dock owner id `id` (== its window id),
    /// including a recoverable owner during context replacement. Lets manager
    /// resolution route a Dock-scoped `workspace_id` before a registered
    /// window's Dock store has been created.
    func tabManagerForWindowDockOwner(_ id: UUID) -> TabManager? {
        if let manager = mainWindowContext(forWindowId: id)?.tabManager {
            return manager
        }
        return recoverableMainWindowRoute(windowId: id)?.tabManager
    }

    /// The Dock of `tabManager`'s window if it already exists, without creating it.
    func existingWindowDock(for tabManager: TabManager) -> DockSplitStore? {
        guard let windowId = windowId(for: tabManager) else { return nil }
        return existingWindowDock(forWindowId: windowId)
    }

    /// Every live per-window Dock store.
    var existingWindowDocks: [DockSplitStore] {
        var seenContexts: Set<ObjectIdentifier> = []
        var seenDocks: Set<ObjectIdentifier> = []
        var docks: [DockSplitStore] = mainWindowContexts.values.compactMap { context in
            guard seenContexts.insert(ObjectIdentifier(context)).inserted,
                  let dock = context.existingWindowDock(),
                  seenDocks.insert(ObjectIdentifier(dock)).inserted else {
                return nil
            }
            return dock
        }
        for dock in recoverableMainWindowDocks()
        where seenDocks.insert(ObjectIdentifier(dock)).inserted {
            docks.append(dock)
        }
        return docks
    }

    /// The window Dock whose tree contains `panelId`, if any.
    func windowDockContainingPanel(_ panelId: UUID) -> DockSplitStore? {
        existingWindowDocks.first { $0.containsPanel(panelId) }
    }

    /// The window Dock whose tree contains `paneId`, if any.
    func windowDockContainingPane(_ paneId: UUID) -> DockSplitStore? {
        existingWindowDocks.first { $0.containsPane(paneId) }
    }

    /// Routes a Ghostty runtime close (close binding, Ctrl-D child exit) for a
    /// window-Dock surface to its owning store. Returns `false` when the
    /// surface is not a window-Dock panel, so the caller falls through to the
    /// workspace path. Window-Dock owner ids are window ids, not workspace tab
    /// ids, so `TabManager.closeRuntimeSurface`-style routing cannot find them.
    @discardableResult
    func closeWindowDockRuntimeSurface(surfaceId: UUID, force: Bool) -> Bool {
        guard let dock = windowDockContainingPanel(surfaceId) else { return false }
        if dock.closePanel(
            surfaceId,
            force: force,
            recordsHistory: false
        ) {
            notificationStore?.clearNotifications(forTabId: dock.workspaceId, surfaceId: surfaceId)
        }
        return true
    }

    /// Tears down the registered window's Dock at an authoritative close boundary.
    ///
    /// Deliberately unconditional: window close is the containing lifecycle,
    /// and a busy Dock panel does not veto it — exactly like the window's
    /// workspace surfaces, which get no per-process veto on this path either.
    /// The menu close path shows the unconditional "Close window?" dialog, and
    /// the last-window/quit path is gated by
    /// `hasQuitConfirmationDirtyWorkspaces()`, which counts window Docks.
    func teardownWindowDock(forWindowId windowId: UUID) {
        mainWindowContext(forWindowId: windowId)?.teardownWindowDock()
    }

    /// Resolves the `TabManager` a Dock's cross-container moves should target.
    /// A Workspace Dock maps to its owning workspace's window; a window Dock
    /// maps to its owning window (its owner id IS that window's id). Fails
    /// closed (`nil`) when the owning window cannot be resolved — a move must
    /// never silently retarget a different window's tree.
    func dockReferenceTabManager(for dock: DockSplitStore) -> TabManager? {
        if dock.scope == .global {
            return tabManagerForWindowDockOwner(dock.workspaceId)
        }
        return tabManagerFor(tabId: dock.workspaceId)
    }
}

extension SessionWindowSnapshot {
    @MainActor
    func omitsRemoteMirrorOnlyWindow(liveWorkspaces: [Workspace]) -> Bool {
        tabManager.workspaces.isEmpty &&
            dock == nil &&
            !liveWorkspaces.isEmpty &&
            liveWorkspaces.allSatisfy { $0.isRemoteTmuxMirror }
    }
}
