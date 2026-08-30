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
/// the gate is `activeRightSidebarMode == .dock`, and the right-sidebar Dock is
/// that window's own Dock (`RightSidebarPanelView` renders the per-window store).
extension AppDelegate {
    /// Returns the coordinator's sidebar mode for shortcut context evaluation.
    /// Dock ownership is published separately as the `dockFocus` context key so
    /// a responder fallback never overwrites a user-visible sidebar mode.
    func focusedSidebarModeForShortcutContext(for window: NSWindow?) -> RightSidebarMode? {
        keyboardFocusCoordinator(for: window)?.activeRightSidebarMode
    }

    /// The Dock store that should receive a creation/split shortcut when the Dock
    /// owns keyboard focus in `preferredWindow`, else `nil` (caller falls through
    /// to the main-area path).
    func focusedDockStoreForShortcut(preferredWindow: NSWindow?) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return nil
        }
        let activeMode = context.keyboardFocusCoordinator.activeRightSidebarMode
        if activeMode == .dock {
            if let sidebarState = context.fileExplorerState,
               !sidebarState.isVisible {
                return nil
            }
            // A mode switch can publish focus before SwiftUI has mounted the
            // Dock host. Preserve the existing lazy-creation contract for that
            // explicit Dock focus, while responder-based fallback remains
            // read-only for non-Dock focus.
            guard let dock = existingWindowDock(forWindowId: context.windowId)
                ?? windowDock(forWindowId: context.windowId)
            else { return nil }
            guard !dock.isRetired else { return nil }
            return dock
        }
        return existingFocusedDockStoreForShortcut(context: context)
    }

    /// Read-only variant used while SwiftUI builds menus or command snapshots.
    /// It never lazily creates a Dock, so evaluating a menu's `body` cannot
    /// mutate the window context or trigger an AttributeGraph invalidation.
    func existingFocusedDockStoreForShortcut(
        preferredWindow: NSWindow?
    ) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return nil
        }
        return existingFocusedDockStoreForShortcut(context: context)
    }

    /// Read-only Dock ownership value for the per-event shortcut context. An
    /// explicit Dock mode is enough to keep a shortcut eligible while SwiftUI
    /// is still mounting the store; unlike ``focusedDockStoreForShortcut``, this
    /// path never creates a Dock as a side effect of context evaluation.
    func dockFocusForShortcutContext(preferredWindow: NSWindow?) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        if context.keyboardFocusCoordinator.activeRightSidebarMode == .dock {
            return context.fileExplorerState?.isVisible != false
        }
        return existingFocusedDockStoreForShortcut(context: context) != nil
    }

    private func existingFocusedDockStoreForShortcut(
        context: MainWindowContext
    ) -> DockSplitStore? {
        if let sidebarState = context.fileExplorerState,
           !sidebarState.isVisible {
            return nil
        }
        guard let dock = existingWindowDock(forWindowId: context.windowId),
              !dock.isRetired,
              dock.isVisibleInUI else { return nil }
        if context.keyboardFocusCoordinator.activeRightSidebarMode == .dock {
            return dock
        }
        guard let window = context.window ?? mainWindow(for: context.windowId),
              dockOwnsFocusedResponder(dock, in: window) else { return nil }
        return dock
    }

    func focusedDockStoreForShortcut(
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?
    ) -> DockSplitStore? {
        guard case .dockScoped =
            action.dockShortcutRoutingDisposition else {
            assertionFailure(
                "Non-Dock-scoped shortcut requested the Dock gate: " +
                    action.rawValue
            )
            return nil
        }
        return focusedDockStoreForShortcut(
            preferredWindow: preferredWindow
        )
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
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?,
        preferredDock: DockSplitStore? = nil
    ) -> Bool {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return false
        }
        let store: DockSplitStore?
        if let preferredDock {
            store = preferredDock.isRetired ? nil : preferredDock
        } else {
            store = focusedDockStoreForShortcut(
                action: action,
                preferredWindow: preferredWindow
            )
        }
        guard let store else {
            return false
        }
        let sourcePanelId = store.focusedPanelId
        let sourceBrowser = kind == .browser
            ? sourcePanelId.flatMap { store.browserPanel(for: $0) }
            : nil
        guard let panelId = store.newSplit(
            kind: kind,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            sourcePanelId: sourcePanelId,
            preferredProfileID: sourceBrowser?.profileID,
            chromeVisibility: sourceBrowser?.chromeVisibility ?? .visible,
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
        return performDockCommand(command, in: store)
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
            assertionFailure(
                "Non-Dock-scoped command requested the Dock gate: " + action.rawValue
            )
            return false
        }
        guard let store = existingFocusedDockStoreForShortcut(
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        return performDockCommand(command, in: store)
    }

    private func performDockCommand(
        _ command: DockShortcutCommand,
        in store: DockSplitStore
    ) -> Bool {
        if command.isFocusHistoryNavigation, !store.focusHistoryIncludesPanesAndTabs {
            return false
        }
        if !store.performShortcutCommand(command) { NSSound.beep() }
        return true
    }

    private func dockOwnsFocusedResponder(
        _ dock: DockSplitStore,
        in window: NSWindow
    ) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let terminalSurface = responder.cmuxTerminalFocusOwningGhosttyView()?.terminalSurface {
            guard terminalSurface.focusPlacement == .rightSidebarDock else {
                return false
            }
            return dock.panelIsSelectedInVisibleDockPane(terminalSurface.id)
        }
        guard let focusedPanelId = dock.focusedPanelId,
              let focusedBrowser = dock.browserPanel(for: focusedPanelId) else {
            return false
        }
        guard focusedBrowser.ownedFocusIntent(for: responder, in: window) != nil else {
            return false
        }
        return dock.panelIsSelectedInVisibleDockPane(focusedBrowser.id)
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
