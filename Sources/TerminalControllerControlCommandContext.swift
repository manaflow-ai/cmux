import CmuxControlSocket
import Foundation

/// `TerminalController` conforms to ``ControlCommandContext`` as the interim
/// composition owner for the stage-3c ``ControlCommandCoordinator``: it reads
/// live `AppDelegate` / `TabManager` state on the main actor so the coordinator
/// (which runs on main, inside the active `withSocketCommandPolicy` stack) can
/// execute moved command domains without the package importing the app target.
///
/// `ControlCommandContext` is the umbrella; `TerminalController` satisfies it by
/// conforming to each domain constituent (one extension per domain file). The
/// umbrella conformance itself carries no requirements.
extension TerminalController: ControlCommandContext {}

/// The window-domain witnesses are the byte-faithful bodies of the former
/// `v2Window*` dispatchers, minus the per-read `v2MainSync` hop: the coordinator
/// already runs on the main actor inside the socket-command policy scope, so each
/// hop would re-apply the identical thread-local focus-allowance stack — a no-op.
extension TerminalController: ControlWindowContext {
    func controlWindowSummaries() -> [ControlWindowSummary] {
        (AppDelegate.shared?.listMainWindowSummaries() ?? []).map { summary in
            ControlWindowSummary(
                windowID: summary.windowId,
                isKeyWindow: summary.isKeyWindow,
                isVisible: summary.isVisible,
                workspaceCount: summary.workspaceCount,
                selectedWorkspaceID: summary.selectedWorkspaceId
            )
        }
    }

    func controlResolveCurrentWindow(
        routing: ControlRoutingSelectors
    ) -> ControlCurrentWindowResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let windowId = AppDelegate.shared?.windowId(for: tabManager) else {
            return .windowNotFound
        }
        return .resolved(windowId)
    }

    func controlFocusWindow(id: UUID) -> Bool {
        AppDelegate.shared?.focusMainWindow(windowId: id) ?? false
    }

    func controlCreateWindowAndActivate() -> UUID? {
        guard let windowId = AppDelegate.shared?.createMainWindow() else { return nil }
        // The new window should become key, but setActiveTabManager defensively
        // (preserves the legacy v2WindowCreate side effect and ordering).
        if let tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) {
            setActiveTabManager(tabManager)
        }
        return windowId
    }

    func controlCloseWindow(id: UUID) -> Bool {
        // force: a programmatic (v2/socket) close must bypass the interactive
        // last-window quit veto and report the truth — same contract as the v1 CLI path.
        AppDelegate.shared?.closeMainWindow(windowId: id, force: true) ?? false
    }

    func controlAvailableDisplays() -> [ControlDisplayInfo] {
        (AppDelegate.shared?.availableDisplays() ?? []).map { display in
            ControlDisplayInfo(
                name: display.name,
                index: display.index,
                displayID: display.displayID,
                isMain: display.isMain,
                frameX: display.frame.origin.x,
                frameY: display.frame.origin.y,
                frameWidth: display.frame.width,
                frameHeight: display.frame.height
            )
        }
    }

    func controlWindowExists(id: UUID) -> Bool {
        AppDelegate.shared?.windowForMainWindowId(id) != nil
    }

    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? {
        AppDelegate.shared?.moveMainWindow(windowId: id, toDisplayMatching: query)
    }

    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? {
        guard let result = AppDelegate.shared?.moveAllMainWindows(toDisplayMatching: query) else {
            return nil
        }
        return ControlMoveAllWindowsResult(display: result.display, windowIDs: result.windowIds)
    }
}
