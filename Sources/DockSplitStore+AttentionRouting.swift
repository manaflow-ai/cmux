import AppKit
import Foundation

@MainActor
extension DockSplitStore {
    /// Resolves the notification authority injected by the owning window.
    ///
    /// Workspace-scoped Docks predate per-window ownership and retain the
    /// late-bound fallback until their construction path can inject the store.
    func resolvedNotificationStore() -> TerminalNotificationStore? {
        notificationStore ?? AppDelegate.shared?.notificationStore
    }

    /// Applies exact unread state for a global-Dock surface through one policy.
    func applyWindowDockUnreadState(_ isUnread: Bool, panelId: UUID) {
        guard scope == .global,
              let notificationStore = resolvedNotificationStore() else {
            return
        }
        if isUnread {
            notificationStore.markWindowDockSurfaceUnread(
                windowId: workspaceId,
                surfaceId: panelId
            )
        } else {
            notificationStore.clearWindowDockSurfaceUnread(
                windowId: workspaceId,
                surfaceId: panelId
            )
        }
    }

    /// Routes a panel attention request through the shared live-container
    /// registry. This is the Dock equivalent of Workspace's panel lookup and is
    /// intentionally container-agnostic: both workspace and global Docks
    /// register in `liveStores`.
    @discardableResult
    static func routeAttentionFlash(
        panelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        shouldFocus: Bool = false
    ) -> Bool {
        guard let dock = liveStore(containingPanel: panelID),
              let panel = dock.panels[panelID],
              panel.panelType == .terminal else {
            return false
        }
        if shouldFocus {
            dock.focusPanel(panelID)
        }
        panel.triggerFlash(reason: reason)
        return true
    }

    /// Gives a Dock-owned terminal Dock-owned flash and visual-BEL callbacks.
    /// A moved terminal can otherwise retain its prior container's closures and
    /// publish attention into the wrong owner.
    func installAttentionRouting(for panel: any Panel) {
        guard let terminal = panel as? TerminalPanel else { return }
        let ownerTabManager = AppDelegate.shared?.dockReferenceTabManager(for: self)
        terminal.surface.onExplicitInput = { [weak self, weak terminal, weak ownerTabManager] in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal else {
                return
            }
            ownerTabManager?.dismissNotificationOnTerminalInteraction(
                tabId: self.workspaceId,
                surfaceId: terminal.id
            )
        }
        terminal.surface.onStartupRestoreAdmissionCancelled = { [weak self, weak terminal] in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal,
                  let restore = self.deferredAgentResumeRestoresByPanelId[terminal.id] else {
                return
            }
            self.cancelDeferredAgentResumeRestore(
                panelId: terminal.id,
                restore: restore
            )
        }
        terminal.onRequestWorkspacePaneFlash = { [weak self, weak terminal] reason in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal else {
                return
            }
            mountedTerminal.hostedView.triggerFlash(
                style: GhosttySurfaceScrollView.flashStyle(for: reason)
            )
        }
        guard scope == .global else {
            // The legacy workspace Dock is not rendered by the sidebar. Audio
            // still rings, but visual BEL attention must not create a phantom
            // workspace target that navigation cannot reveal.
            terminal.surface.onVisualBell = nil
            return
        }
        terminal.surface.onVisualBell = { [weak self, weak terminal] in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal else {
                return
            }
            let ownsActiveFocus = self.ownerWindowHasActiveFocus(for: terminal)
                && self.panelIsActiveInVisibleDockPane(terminal.id)
                && AppDelegate.shared?.focusedDockStoreForShortcut(
                    preferredWindow: terminal.surface.uiWindow
                ) === self
            if !ownsActiveFocus,
               let notificationStore = self.resolvedNotificationStore(),
               !notificationStore.hasManualUnread(
                    forTabId: self.workspaceId,
                    surfaceId: terminal.id
               ) {
                notificationStore.markWindowDockSurfaceUnread(
                    windowId: self.workspaceId,
                    surfaceId: terminal.id
                )
            }
            mountedTerminal.triggerFlash(reason: .notificationArrival)
        }
    }

    /// Whether this Dock terminal's owning main window currently owns app focus.
    private func ownerWindowHasActiveFocus(for terminal: TerminalPanel) -> Bool {
        AppFocusState.isAppFocused()
            && terminal.surface.uiWindow?.isKeyWindow == true
    }
}
