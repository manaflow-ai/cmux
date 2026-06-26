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
        AppDelegate.shared?.closeMainWindow(windowId: id) ?? false
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

    // MARK: - v1 line-protocol witnesses

    // The byte-faithful bodies of the former `TerminalController` v1 window
    // cases, moved here verbatim so the coordinator's `handleWindowV1` dispatch
    // owns the routing while the app-coupled bodies stay app-resident. The v1
    // `list_windows` formatter now lives in the coordinator (built from the
    // shared `controlWindowSummaries()`), so it has no witness here.

    func controlCurrentWindowV1() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        guard let windowId = v2ResolveWindowId(tabManager: tabManager) else { return "ERROR: No active window" }
        return windowId.uuidString
    }

    func controlFocusWindowV1(arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }

        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        guard ok else { return "ERROR: Window not found" }

        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK"
    }

    func controlNewWindowV1() -> String {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return "ERROR: Failed to create window"
        }
        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK \(windowId.uuidString)"
    }

    func controlCloseWindowV1(arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok ? "OK" : "ERROR: Window not found"
    }

    func controlMoveWorkspaceToWindowV1(args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage move_workspace_to_window <workspace_id> <window_id>" }
        guard let wsId = UUID(uuidString: parts[0]) else { return "ERROR: Invalid workspace id" }
        guard let windowId = UUID(uuidString: parts[1]) else { return "ERROR: Invalid window id" }

        var ok = false
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId),
                  let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId),
                  let ws = srcTM.detachWorkspace(tabId: wsId) else {
                ok = false
                return
            }
            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            ok = true
        }

        return ok ? "OK" : "ERROR: Move failed"
    }
}
