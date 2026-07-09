import CmuxControlSocket
import CmuxWindowing
import Foundation

/// `TerminalController` conforms to ``ControlCommandContext`` as the interim
/// composition owner for the stage-3c ``ControlCommandCoordinator``: it reads
/// live `AppDelegate` / `TabManager` state on the main actor so the coordinator
/// (which runs on main, inside the active `withSocketCommandPolicy` stack) can
/// execute moved command domains without the package importing the app target.
///
/// `ControlCommandContext` is the umbrella; `TerminalController` satisfies it by
/// conforming to each domain constituent (one extension per domain file). The
/// umbrella carries one requirement of its own: the worker-lane resolution hop.
extension TerminalController: ControlCommandContext {
    /// The worker-lane resolution hop primitive: forwards to `v2MainSync` (so
    /// the hop collapses to an inline call when the caller is already on the
    /// main thread, propagates the focus-allowance stack, and records per-hop
    /// timing exactly like every other socket main hop) and refreshes the
    /// known `kind:N` refs FIRST, mirroring the main-lane dispatch preamble
    /// (`v2MainActorResponse`) byte-for-byte so caller-supplied refs resolve.
    /// NOTE: the refresh covers only main-window workspace topology; dock-hosted
    /// surfaces/panes (the per-window `DockSplitStore`s, post-#7144) are
    /// first-minted by each body's in-hop mint pass, so every mint pass MUST
    /// preserve its payload's literal mint order — that ordering, not the
    /// refresh, is what keeps `kind:N` ordinals identical to the legacy build.
    /// The body receives `self` back as its main-actor seam parameter (see the
    /// protocol requirement's doc).
    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        v2MainSync {
            self.v2RefreshKnownRefs()
            return body(self)
        }
    }
}

/// The window-domain witnesses are the byte-faithful bodies of the former
/// `v2Window*` dispatchers, minus the per-read `v2MainSync` hop: the coordinator
/// already runs on the main actor inside the socket-command policy scope, so each
/// hop would re-apply the identical thread-local focus-allowance stack — a no-op.
extension TerminalController: ControlWindowContext {
    func controlWindowSummaries() -> [ControlWindowSummary] {
        (appEnvironment?.windowRegistry.listMainWindowSummaries() ?? []).map { summary in
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
        guard let windowId = appEnvironment?.windowRegistry.windowId(for: tabManager) else {
            return .windowNotFound
        }
        return .resolved(windowId)
    }

    func controlFocusWindow(id: UUID) -> Bool {
        appEnvironment?.mainWindowRouter.focusMainWindow(windowId: id) ?? false
    }

    func controlCreateWindowAndActivate() -> UUID? {
        guard let windowId = appEnvironment?.mainWindowRouter.createMainWindow() else { return nil }
        // The new window should become key, but setActiveTabManager defensively
        // (preserves the legacy v2WindowCreate side effect and ordering).
        if let tabManager = appEnvironment?.windowRegistry.tabManagerFor(windowId: windowId) {
            setActiveTabManager(tabManager)
        }
        return windowId
    }

    func controlCloseWindow(id: UUID) -> Bool {
        appEnvironment?.mainWindowRouter.closeMainWindow(windowId: id) ?? false
    }

    func controlAvailableDisplays() -> [ControlDisplayInfo] {
        // Preserve the legacy `AppDelegate.shared?.availableDisplays() ?? []`
        // nil-guard: before launch wiring (and at teardown) `shared` is nil, and
        // the command must report no displays rather than read live NSScreen
        // state. The display-summary body itself is the lifted
        // `DisplayInfo.connectedDisplays()`.
        guard AppDelegate.shared != nil else { return [] }
        return DisplayInfo.connectedDisplays().map { display in
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
        appEnvironment?.mainWindowRouter.moveWindow(windowId: id, toDisplayMatching: query)
    }

    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? {
        guard let result = appEnvironment?.mainWindowRouter.moveAllWindows(toDisplayMatching: query) else {
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

        let ok = v2MainSync { appEnvironment?.mainWindowRouter.focusMainWindow(windowId: windowId) ?? false }
        guard ok else { return "ERROR: Window not found" }

        if let tm = v2MainSync({ appEnvironment?.windowRegistry.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK"
    }

    func controlNewWindowV1() -> String {
        guard let windowId = v2MainSync({ appEnvironment?.mainWindowRouter.createMainWindow() }) else {
            return "ERROR: Failed to create window"
        }
        if let tm = v2MainSync({ appEnvironment?.windowRegistry.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK \(windowId.uuidString)"
    }

    func controlCloseWindowV1(arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }
        let ok = v2MainSync { appEnvironment?.mainWindowRouter.closeMainWindow(windowId: windowId) ?? false }
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
            guard let srcTM = appEnvironment?.windowRegistry.tabManagerFor(tabId: wsId),
                  let dstTM = appEnvironment?.windowRegistry.tabManagerFor(windowId: windowId),
                  let ws = srcTM.detachWorkspace(tabId: wsId) else {
                ok = false
                return
            }
            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = appEnvironment?.mainWindowRouter.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            ok = true
        }

        return ok ? "OK" : "ERROR: Move failed"
    }
}
