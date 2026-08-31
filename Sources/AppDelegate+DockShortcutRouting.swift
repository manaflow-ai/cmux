import AppKit
import Bonsplit
import CmuxPanes

enum GhosttyGotoSplitRoute {
    case direction(NavigationDirection)
    case previous
    case next
}

extension KeyboardShortcutSettings.Action {
    var dockShortcutRoutingDisposition:
        DockShortcutRoutingDisposition {
        switch self {
        case .triggerFlash,
             .nextSurface, .prevSurface,
             .moveSurfaceLeft, .moveSurfaceRight,
             .moveSurfaceToPreviousPane, .moveSurfaceToNextPane,
             .moveSurfaceToPaneLeft, .moveSurfaceToPaneRight,
             .moveSurfaceToPaneUp, .moveSurfaceToPaneDown,
             .selectSurfaceByNumber,
             .focusHistoryBack, .focusHistoryForward,
             .renameTab,
             .closeTab, .closeOtherTabsInPane,
             .reopenClosedBrowserPanel,
             .newSurface,
             .toggleTerminalCopyMode,
             .focusTextBoxInput, .attachTextBoxFile,
             .sendCtrlFToTerminal,
             .clearScreenKeepScrollback,
             .focusLeft, .focusRight, .focusUp, .focusDown,
             .focusPreviousPane, .focusNextPane,
             .splitRight, .splitDown, .toggleSplitZoom,
             .equalizeSplits,
             .splitBrowserRight, .splitBrowserDown,
             .openBrowser, .focusBrowserAddressBar,
             .find, .findNext, .findPrevious, .hideFind,
             .useSelectionForFind,
             .toggleReactGrab:
            .dockScoped

        case .commandPaletteNext, .commandPalettePrevious,
             .toggleChecklistItemComplete,
             .cycleTextBoxSubmitAction,
             .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias,
             .saveFilePreview,
             .browserBack, .browserForward,
             .browserReload, .browserHardReload,
             .browserZoomIn, .browserZoomOut, .browserZoomReset,
             .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole,
             .toggleBrowserFocusMode,
             .toggleBrowserDesignMode,
             .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .simulatorHome, .simulatorRotateLeft,
             .simulatorRotateRight,
             .simulatorToggleAppearance,
             .simulatorToggleSoftwareKeyboard,
             .diffViewerNextFile, .diffViewerPreviousFile:
            .focusResolved

        case .openSettings, .reloadConfiguration,
             .showHideAllWindows, .globalSearch,
             .newWindow, .closeWindow, .toggleFullScreen, .quit,
             .toggleSidebar, .newTab, .newBrowserWorkspace,
             .saveLayoutTemplate, .openFolder,
             .reopenPreviousSession, .goToWorkspace,
             .commandPalette, .sendFeedback,
             .showNotifications, .jumpToUnread, .toggleUnread,
             .markOldestUnreadAndJumpNext,
             .markAllNotificationsRead, .clearAllNotifications,
             .focusRightSidebar,
             .switchRightSidebarToFiles,
             .switchRightSidebarToFind,
             .switchRightSidebarToSessions,
             .switchRightSidebarToFeed,
             .switchRightSidebarToDock,
             .switchRightSidebarToMachines,
             .nextSidebarTab, .prevSidebarTab,
             .nextSidebarTabInGroup, .prevSidebarTabInGroup,
             .moveWorkspaceUp, .moveWorkspaceDown,
             .selectWorkspaceByNumber,
             .renameWorkspace, .editWorkspaceDescription,
             .markWorkspaceDone, .cycleWorkspaceStatus,
             .closeWorkspace,
             .newWorkspaceGroup, .groupSelectedWorkspaces,
             .toggleFocusedWorkspaceGroupCollapsed,
             .reopenClosedWorkspace,
             .increaseWorkspaceTerminalFontSize,
             .decreaseWorkspaceTerminalFontSize,
             .resetWorkspaceTerminalFontSize,
             .toggleCanvasLayout,
             .canvasRevealFocusedPane, .canvasOverview,
             .canvasZoomIn, .canvasZoomOut, .canvasZoomReset,
             .canvasTidy,
             .canvasAlignLeft, .canvasAlignRight,
             .canvasAlignTop, .canvasAlignBottom,
             .canvasEqualizeWidths, .canvasEqualizeHeights,
             .canvasDistributeHorizontally,
             .canvasDistributeVertically,
             .toggleRightSidebar,
             .findInDirectory,
             .openDiffViewer:
            .mainContainer
        }
    }
}

/// Routes "create a surface" keyboard shortcuts (New Browser, New Terminal,
/// Split Right/Down) into the Dock when the Dock currently owns keyboard focus.
///
/// Without this, every creation shortcut targets the main content `tabManager`,
/// so pressing e.g. Cmd+Shift+L while a Dock pane is focused spawned a browser in
/// the main split tree instead of the Dock. Mirrors the existing focus-gated
/// routing in `closeFocusedDockPanelForCommand` (`Workspace+DockBrowserLookup.swift`):
/// the gate is `focusedRightSidebarMode == .dock`, and the right-sidebar Dock is
/// that window's own Dock (`RightSidebarPanelView` renders the per-window store).
extension AppDelegate {
    /// Returns the reconciled sidebar mode for shortcut context evaluation.
    /// Pending intent remains visible to right-sidebar-scoped shortcuts; the
    /// separate `dockFocus` key is the delivered/executable Dock gate.
    func focusedSidebarModeForShortcutContext(for window: NSWindow?) -> RightSidebarMode? {
        guard let coordinator = keyboardFocusCoordinator(for: window),
              let mode = coordinator.resolvedRightSidebarModeForShortcut(in: window) else {
            return nil
        }
        return mode
    }

    /// The existing, visible Dock store that owns keyboard focus in
    /// `preferredWindow`, else `nil` (caller falls through to its normal
    /// container). This is deliberately read-only: menu/body and shortcut
    /// context evaluation must not create a Dock as a side effect.
    func focusedDockStoreForShortcut(preferredWindow: NSWindow?) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return nil
        }
        return dockStoreForShortcut(context: context)
    }

    /// Returns the Dock for menu enablement from the delivered focus snapshot.
    /// This path is intentionally bounded: Commands must not traverse a Dock's
    /// responder, panel, or Bonsplit collections while rebuilding the menu.
    /// Menu action execution calls this same resolver, so enablement and the
    /// mutation target cannot disagree.
    func focusedDockStoreForMenu(preferredWindow: NSWindow?) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(
            preferredWindow: preferredWindow
        ),
        let sidebarState = context.fileExplorerState,
        sidebarState.isVisible,
        context.keyboardFocusCoordinator.focusedRightSidebarMode == .dock,
        let dock = existingWindowDock(forWindowId: context.windowId),
        !dock.isRetired,
        dock.isVisibleInUI else {
            return nil
        }
        return dock
    }

    /// Clears a Dock pointer-origin transaction when a key event begins in the
    /// owning window. Pointer callbacks may be absent for a slop-area click;
    /// keyboard focus changes must never allow that released origin to leak
    /// into a later programmatic Bonsplit selection.
    func cancelDockPointerOriginForKeyEvent(in window: NSWindow?) {
        guard let window,
              let context = mainWindowContexts[ObjectIdentifier(window)]
                  ?? mainWindowContexts.values.first(where: { $0.window === window }),
              let dock = context.existingWindowDock() else {
            return
        }
        dock.cancelDockPointerInteraction(window: window)
    }

    /// Validates a Dock captured by the command palette without collapsing
    /// workspace-scoped and window-scoped Docks into the window-focus gate.
    /// Window Docks must still own the current sidebar focus; workspace Docks
    /// are validated against their owning workspace's live store and panel map.
    func isCurrentCommandPaletteDockTarget(
        _ dock: DockSplitStore,
        panelId: UUID,
        preferredWindow: NSWindow?
    ) -> Bool {
        guard !dock.isRetired, dock.panels[panelId] != nil else { return false }

        switch dock.scope {
        case .global:
            guard let context = preferredRegisteredMainWindowContext(
                preferredWindow: preferredWindow
            ),
            let ownerDock = existingWindowDock(forWindowId: context.windowId),
            ownerDock === dock,
            context.fileExplorerState?.isVisible == true,
            dock.isVisibleInUI else {
                return false
            }
            // The command palette owns first responder while the command runs;
            // the captured, visible Dock is authoritative until dismissal even
            // if the focus coordinator temporarily observes the palette host.
            return true

        case .workspace:
            guard let manager = tabManagerFor(tabId: dock.workspaceId),
                  let workspace = manager.tabs.first(where: {
                      $0.id == dock.workspaceId
                  }),
                  workspace._dockSplit === dock,
                  dock.isVisibleInUI,
                  DockSplitStore.liveStore(containingPanel: panelId) === dock else {
                return false
            }
            return true
        }
    }

    /// Read-only Dock ownership value for the per-event shortcut context. It
    /// reports only an existing, visible Dock owned by either the delivered
    /// coordinator state or its structured responder fallback, so context and
    /// command/menu gates agree during SwiftUI remounts.
    func dockFocusForShortcutContext(
        preferredWindow: NSWindow?,
        resolvedSidebarMode: RightSidebarMode? = nil
    ) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        return dockStoreForShortcut(
            context: context,
            resolvedSidebarMode: resolvedSidebarMode
        ) != nil
    }

    private func dockStoreForShortcut(
        context: MainWindowContext,
        resolvedSidebarMode: RightSidebarMode? = nil
    ) -> DockSplitStore? {
        guard let sidebarState = context.fileExplorerState,
              sidebarState.isVisible else { return nil }
        guard let dock = existingWindowDock(forWindowId: context.windowId),
              !dock.isRetired,
              dock.isVisibleInUI else {
            return nil
        }
        // The delivered state is the common steady-state path used by menu
        // reconstruction and execution. It avoids touching Dock panel maps in
        // the Commands body. During a real responder handoff, fall back to the
        // structured responder check so a Dock portal can still receive the
        // first shortcut before its host publishes `.focused`.
        if context.keyboardFocusCoordinator.focusedRightSidebarMode == .dock {
            return dock
        }
        let responderOwnsDock = dockResponderOwnsFocus(
            dock,
            in: context.window
        )
        guard responderOwnsDock else { return nil }
        let resolvedMode = resolvedSidebarMode
            ?? context.keyboardFocusCoordinator.resolvedRightSidebarModeForShortcut(
                in: context.window
            )
        return resolvedMode == .dock ? dock : nil
    }

    /// Confirms that a registry-resolved Dock responder is live, rather than a
    /// pending sidebar-mode request whose previous responder is still active.
    private func dockResponderOwnsFocus(
        _ dock: DockSplitStore,
        in window: NSWindow?
    ) -> Bool {
        guard let window, let responder = window.firstResponder else {
            return false
        }
        if let ghosttyView = responder.cmuxStrictOwningGhosttyView(),
           let panelId = ghosttyView.terminalSurface?.id {
            return dock.containsPanel(panelId)
                && dock.panelIsSelectedInVisibleDockPane(panelId)
        }
        if let panelId = dock.focusedPanelId,
           let panel = dock.panels[panelId],
           dock.panelIsSelectedInVisibleDockPane(panelId),
           panel.ownedFocusIntent(for: responder, in: window) != nil {
            return true
        }
        return false
    }

    func focusedDockStoreForShortcut(
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?
    ) -> DockSplitStore? {
        guard case .dockScoped =
            action.dockShortcutRoutingDisposition else {
            // Keep dynamically assembled menu/shortcut callers fail-closed;
            // the exhaustive disposition switch remains the source of truth.
            return nil
        }
        return focusedDockStoreForShortcut(
            preferredWindow: preferredWindow
        )
    }

    /// Resolves the visible Dock for a surface-tree command that is not tied to
    /// one particular shortcut binding (for example, a left/up menu split).
    /// The focus/visibility predicate is shared with configured shortcuts, but
    /// the command is intentionally independent of any unrelated action's
    /// custom binding or `when` clause.
    func focusedDockStoreForSurfaceCommand(
        preferredWindow: NSWindow?
    ) -> DockSplitStore? {
        focusedDockStoreForMenu(preferredWindow: preferredWindow)
    }

    /// Creates a New Terminal / New Browser surface in the focused Dock pane.
    /// Returns the created Dock panel id when handled, or `nil` to fall through to
    /// the main-area creation path.
    @discardableResult
    func routeCreateToFocusedDock(
        _ kind: DockSurfaceKind,
        focusAddressBar: Bool,
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?
    ) -> UUID? {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return nil
        }
        guard let store = focusedDockStoreForShortcut(
                  action: action,
                  preferredWindow: preferredWindow
              ),
              let pane = store.resolvePane(requestedPaneID: nil),
              let panelId = store.newSurface(kind: kind, inPane: pane, focus: true) else {
            return nil
        }
        if focusAddressBar, kind == .browser, let browser = store.browserPanel(for: panelId) {
            focusBrowserAddressBar(in: browser)
        }
        return panelId
    }

    /// Splits the focused Dock pane (terminal or browser). Returns `true` when
    /// handled, or `false` to fall through to the main-area split path. Reuses the
    /// main area's `SplitDirection` → orientation/insert mapping so Dock splits
    /// match the main split affordances (Cmd+D = side-by-side, Cmd+Shift+D = stacked).
    @discardableResult
    func routeSplitToFocusedDock(
        kind: DockSurfaceKind,
        direction: SplitDirection,
        action: KeyboardShortcutSettings.Action? = nil,
        preferredWindow: NSWindow?,
        preferredDock: DockSplitStore? = nil,
        preferredDockPanelId: UUID? = nil
    ) -> Bool {
        // Configured shortcut callers provide an action so the exhaustive
        // disposition switch remains the authorization source of truth. Menu
        // and palette callers may use the direction-agnostic surface command
        // path without borrowing an unrelated left/right shortcut identity.
        if let action {
            guard case .dockScoped = action.dockShortcutRoutingDisposition else {
                return false
            }
        }
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return false
        }
        let store: DockSplitStore?
        if let preferredDock {
            // Command-palette handlers retain the Dock captured at presentation
            // time. Revalidate that capture against the scope-aware ownership
            // predicate so a sidebar/mode change cannot mutate a hidden or
            // stale Dock (including a workspace-scoped Dock).
            let capturedPanelId = preferredDockPanelId
                ?? preferredDock.focusedPanelId
            store = capturedPanelId.flatMap {
                isCurrentCommandPaletteDockTarget(
                    preferredDock,
                    panelId: $0,
                    preferredWindow: preferredWindow
                ) ? preferredDock : nil
            }
        } else {
            if action == nil {
                // Menu/compatibility callers have no event-scoped binding;
                // use the delivered menu snapshot. Configured shortcuts use
                // the responder-aware resolver below.
                store = focusedDockStoreForSurfaceCommand(
                    preferredWindow: preferredWindow
                )
            } else {
                store = focusedDockStoreForShortcut(
                    preferredWindow: preferredWindow
                )
            }
        }
        guard let store else {
            return false
        }
        // A palette caller may have authorized a panel that is not currently
        // selected in the Dock (focus can lag while the palette dismisses).
        // Preserve that validated identity as the split source instead of
        // re-reading a potentially different focused pane.
        let sourcePanelId = preferredDockPanelId ?? store.focusedPanelId
        let sourceBrowser = kind == .browser
            ? sourcePanelId.flatMap { store.browserPanel(for: $0) }
            : nil
        guard let panelId = store.newSplit(
            kind: kind,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            sourcePanelId: sourcePanelId,
            preferredProfileID: sourceBrowser?.profileID,
            // This is a new, URL-less split rather than a duplicate. Keep the
            // address bar visible even when the source browser is chromeless;
            // inheriting that fixed pane policy would create an unreachable
            // blank browser and diverge from the main split behavior.
            chromeVisibility: .visible,
            websiteDataStore: sourceBrowser?.explicitEphemeralWebsiteDataStoreForSibling,
            focus: true
        ) else {
            return false
        }
        if kind == .browser,
           let browser = store.browserPanel(for: panelId) {
            _ = focusBrowserAddressBar(in: browser)
        }
        return true
    }

    /// Executes a semantic surface/focus command when the Dock owns keyboard
    /// focus. Callers invoke this from the command's existing dispatcher
    /// position so configured and compatibility shortcuts keep the same
    /// conflict precedence as the main area.
    func performFocusedDockShortcut(
        _ command: DockShortcutCommand,
        action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        guard let store = focusedDockStoreForShortcut(
            action: action,
            preferredWindow: event.window
        ) else {
            return false
        }
        guard !command.isFocusHistoryNavigation
            || store.focusHistoryIncludesPanesAndTabs else {
            return false
        }
        guard !command.requiresTerminalSurface || store.focusedDockPanelIsTerminal else {
            NSSound.beep()
            return true
        }
        performDockCommand(command, in: store)
        return true
    }

    /// Executes a Dock-owned command from a menu or another synchronous entry
    /// point that has no key event. Keyboard and menu dispatch share this path so
    /// focus-history guards, failed-command beeps, and Dock ownership cannot
    /// diverge between entrypoints.
    @discardableResult
    func performFocusedDockCommand(
        _ command: DockShortcutCommand,
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?
    ) -> Bool {
        guard case .dockScoped = action.dockShortcutRoutingDisposition else {
            return false
        }
        guard let store = focusedDockStoreForMenu(
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        guard !command.isFocusHistoryNavigation
            || store.focusHistoryIncludesPanesAndTabs else {
            return false
        }
        guard !command.requiresTerminalSurface || store.focusedDockPanelIsTerminal else {
            NSSound.beep()
            return true
        }
        performDockCommand(command, in: store)
        return true
    }

    private func performDockCommand(
        _ command: DockShortcutCommand,
        in store: DockSplitStore
    ) {
        if !store.performShortcutCommand(command) { NSSound.beep() }
    }

    func matchesLegacyNextSurfaceShortcut(event: NSEvent) -> Bool {
        matchTabShortcut(
            event: event,
            shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)
        )
    }

    func matchesLegacyPreviousSurfaceShortcut(event: NSEvent) -> Bool {
        matchTabShortcut(
            event: event,
            shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)
        )
    }

    func ghosttyGotoSplitShortcut(for direction: NavigationDirection) -> StoredShortcut? {
        switch direction {
        case .left: ghosttyGotoSplitLeftShortcut
        case .right: ghosttyGotoSplitRightShortcut
        case .up: ghosttyGotoSplitUpShortcut
        case .down: ghosttyGotoSplitDownShortcut
        }
    }

    func ghosttyGotoSplitShortcut(for route: GhosttyGotoSplitRoute) -> StoredShortcut? {
        switch route {
        case let .direction(direction):
            ghosttyGotoSplitShortcut(for: direction)
        case .previous:
            ghosttyGotoSplitPreviousShortcut
        case .next:
            ghosttyGotoSplitNextShortcut
        }
    }

    /// Ghostty's imported `goto_split` bindings are compatibility fallbacks, not
    /// peers of cmux's live shortcut configuration. Any configured cmux action
    /// that currently owns the stroke wins. Keeping this arbitration in one
    /// place prevents cached Ghostty bindings from shadowing later handlers
    /// after a Settings rebind.
    func matchesGhosttyGotoSplitFallback(
        event: NSEvent,
        route: GhosttyGotoSplitRoute
    ) -> Bool {
        guard event.type == .keyDown,
              let shortcut = ghosttyGotoSplitShortcut(for: route),
              matchesRawGhosttyGotoSplitShortcut(event: event, shortcut: shortcut, route: route) else {
            return false
        }

        return !KeyboardShortcutSettings.Action.allCases.contains { action in
            liveConfiguredShortcut(action, owns: event)
        }
    }

    private func matchesRawGhosttyGotoSplitShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        route: GhosttyGotoSplitRoute
    ) -> Bool {
        switch route {
        case let .direction(direction):
            let directionalKey = directionalArrowKey(for: direction)
            return matchDirectionalShortcut(
                event: event,
                shortcut: shortcut,
                arrowGlyph: directionalKey.glyph,
                arrowKeyCode: directionalKey.keyCode
            )
        case .previous, .next:
            guard !shortcut.hasChord else { return false }
            return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
        }
    }

    private func liveConfiguredShortcut(
        _ action: KeyboardShortcutSettings.Action,
        owns event: NSEvent
    ) -> Bool {
        if action.usesNumberedDigitMatching {
            return routableNumberedConfiguredShortcutDigit(event: event, action: action) != nil
        }

        let directionalKey: (glyph: String, keyCode: UInt16)? = switch action {
        case .focusLeft: directionalArrowKey(for: .left)
        case .focusRight: directionalArrowKey(for: .right)
        case .focusUp: directionalArrowKey(for: .up)
        case .focusDown: directionalArrowKey(for: .down)
        default: nil
        }
        if let directionalKey {
            return matchConfiguredDirectionalShortcut(
                event: event,
                action: action,
                arrowGlyph: directionalKey.glyph,
                arrowKeyCode: directionalKey.keyCode
            )
        }
        return matchConfiguredShortcut(event: event, action: action)
    }

    private func directionalArrowKey(
        for direction: NavigationDirection
    ) -> (glyph: String, keyCode: UInt16) {
        switch direction {
        case .left: ("←", 123)
        case .right: ("→", 124)
        case .up: ("↑", 126)
        case .down: ("↓", 125)
        }
    }
}
