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
/// umbrella carries one requirement of its own: the worker-lane resolution hop.
extension TerminalController: ControlCommandContext {
    /// The worker-lane resolution hop primitive: forwards to `v2MainSync` (so
    /// the hop collapses to an inline call when the caller is already on the
    /// main thread, propagates the focus-allowance stack, and records per-hop
    /// timing exactly like every other socket main hop) and refreshes the
    /// known `kind:N` refs FIRST, mirroring the main-lane dispatch preamble
    /// (`v2MainActorResponse`) byte-for-byte: caller-supplied refs resolve,
    /// and every live-topology id the closure mints is already minted, so
    /// payload ordinals cannot drift. The body receives `self` back as its
    /// main-actor seam parameter (see the protocol requirement's doc).
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
}
