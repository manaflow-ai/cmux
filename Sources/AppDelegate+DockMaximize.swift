import AppKit

enum DockMaximizeRequest: Equatable, Sendable {
    case maximize
    case restore
    case toggle

    func resolvedMaximized(currentlyMaximized: Bool) -> Bool {
        switch self {
        case .maximize: return true
        case .restore: return false
        case .toggle: return !currentlyMaximized
        }
    }
}

extension AppDelegate {
    /// Shared by the socket command, the shortcut, the Dock chrome button and
    /// the command palette.
    @discardableResult
    func applyDockMaximize(_ request: DockMaximizeRequest, preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let state = context.fileExplorerState else {
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
        let maximize = request.resolvedMaximized(currentlyMaximized: state.isDockMaximized)
#if DEBUG
        cmuxDebugLog(
            "dock.maximize request=\(request) maximize=\(maximize ? 1 : 0) " +
                "wasMaximized=\(state.isDockMaximized ? 1 : 0) visible=\(state.isVisible ? 1 : 0) " +
                "mode=\(state.mode.rawValue) sidebarFocus=\(state.rightSidebarOwnsInputFocus ? 1 : 0)"
        )
#endif
        if maximize {
            guard RightSidebarMode.dock.isAvailable() else { return false }
            if !state.isDockMaximized {
                state.restoresMainFocusOnDockRestore = !state.rightSidebarOwnsInputFocus
            }
            state.setDockMaximized(true)
            guard state.isDockMaximized else { return false }
            _ = focusRightSidebarInActiveMainWindow(mode: .dock, focusFirstItem: true, preferredWindow: window)
            return true
        }

        guard state.isDockMaximized else { return true }
        var returnsMainFocus = state.restoresMainFocusOnDockRestore
        state.restoresMainFocusOnDockRestore = false
        state.setDockMaximized(false)
        if !state.isVisible || state.mode != .dock {
            returnsMainFocus = true
        }
        if returnsMainFocus {
            // The main area's portals come back on the next layout pass.
            DispatchQueue.main.async { [weak context] in
                _ = context?.keyboardFocusCoordinator.restoreFocusedPanelFocusFromRightSidebarIfNeeded()
            }
        }
        return true
    }
}
