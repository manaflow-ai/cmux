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
             .focusRightSidebar,
             .switchRightSidebarToFiles,
             .switchRightSidebarToFind,
             .switchRightSidebarToSessions,
             .switchRightSidebarToFeed,
             .switchRightSidebarToDock,
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
    /// The Dock store that should receive a creation/split shortcut when the Dock
    /// owns keyboard focus in `preferredWindow`, else `nil` (caller falls through
    /// to the main-area path).
    func focusedDockStoreForShortcut(preferredWindow: NSWindow?) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return nil
        }
        guard context.keyboardFocusCoordinator.activeRightSidebarMode == .dock else {
            return nil
        }
        // Dock mode showing means the right sidebar rendered this window's own
        // Dock (which created it), so this resolves the store already on screen.
        // No workspace-Dock fallback: the sidebar never renders one, so routing
        // a creation shortcut there would target an invisible tree.
        return windowDock(forWindowId: context.windowId)
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
        preferredWindow: NSWindow?
    ) -> Bool {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return false
        }
        guard let store = focusedDockStoreForShortcut(
            action: action,
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        guard let panelId = store.newSplit(
            kind: kind,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            sourcePanelId: store.focusedPanelId,
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
        if command.isFocusHistoryNavigation, !store.focusHistoryIncludesPanesAndTabs {
            return false
        }
        if !store.performShortcutCommand(command) { NSSound.beep() }
        return true
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
