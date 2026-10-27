import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

// Creating workspaces and windows. A window exists only while it owns a
// workspace, so a new window is never opened empty: the workspace is
// claimed for its window before the create command is sent, and reconcile
// opens (or fills) that window in the same step that first mirrors the
// workspace, whichever of the command reply and the daemon delta comes
// first.
extension WindowManager {
    /// Creates a workspace with one terminal on `daemon` (default: the local
    /// daemon), placed in window `windowID` when given (see `claimNew`).
    /// Returns its id.
    func createWorkspace(cwd: String? = nil, on daemon: DaemonService? = nil, into windowID: String? = nil,
                         frame: CGRect? = nil, newTabPage: Bool = false, inputToken: String? = nil) async -> String? {
        let daemon = daemon ?? services.daemon
        var spawn = WorkspaceSpawn(cwd: cwd, newTabPage: newTabPage)
        spawn.inputToken = inputToken
        do {
            return try await createWorkspace(spawn, on: daemon, into: windowID, frame: frame)
        } catch {
            daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// New workspace, on the New Tab page, in `state`'s window when it is
    /// open, else in a new window (the app has no open window: Dock, CLI, menu).
    /// `slot` places it in that window's sidebar once it is reported.
    func newWorkspace(in state: WindowState?, on daemon: DaemonService? = nil, at slot: WorkspaceSlot? = nil) {
        let target = targetWindow(preferring: state?.id)
        var spawn = WorkspaceSpawn(newTabPage: true)
        spawn.slot = slot
        Task { [services] in
            do {
                _ = try await createWorkspace(spawn, on: daemon, into: target)
            } catch {
                (daemon ?? services.daemon).logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// New window with a new workspace. Returns the window id right away;
    /// the window opens once the daemon reports the workspace.
    @discardableResult
    /// `holdingKeysFrom`: Cmd-Shift-N's window; keys typed there meanwhile go to the new page (cx-kql5h).
    func newWindow(frame: CGRect? = nil, holdingKeysFrom keyWindow: NSWindow? = nil) -> String {
        let windowID = UUID().uuidString.lowercased(), input = services.keyRouter.newTabInputCoordinator
        // cmux Classic Mode opens a terminal, not a page: no page would take the held keys.
        let keys = NewTabKind.terminalFirst(services) ? nil : input.beginIncoming(in: keyWindow, followsNewWindow: true)
        Task { [services] in
            let made = await createWorkspace(into: windowID, frame: frame, newTabPage: true, inputToken: keys)
            input.endIncoming(keys, pageMade: made != nil); withExtendedLifetime(services) {}
        }
        return windowID
    }

    /// Dock click, Show cmux: the last closed window comes back with its
    /// workspaces; with none registered, a new window with a new workspace, whose id this returns.
    /// Before the launch window opened (`restoreWhenLoaded`), nothing: it is the window that comes back.
    @discardableResult
    func reopenOrCreateWindow() -> String? {
        if launchWindowWaiting || reopenClosedWindow() { return nil }
        return newWindow()
    }

    /// `preferred` when that window is open, else a new window id. The launch window counts as open
    /// before restore registers it (it shows the connecting state outside the registry): a workspace
    /// asked for in it while the app connects lands in it, never in a second window beside it, which
    /// left the launch window on Home and the new terminal behind it (dogfood gate v2.2.3, `type`).
    func targetWindow(preferring preferred: String?) -> String {
        if let preferred, registry.value.window(preferred)?.isOpen == true || awaitsRestore(preferred) { return preferred }
        return UUID().uuidString.lowercased()
    }

    /// The launch window before restore registered it: a workspace claimed for it waits for the
    /// restore's reconcile, which registers it under the identity the restore gives it
    /// (`adoptLaunchWindow`) with every workspace the live tree has.
    /// Neither its registration (a reconcile before the restore registers it, in a registry the restore
    /// replaces) nor its controller (built behind a saved picture) ends this: only the restore applying the
    /// saved registry does (`savedRegistryApplied`).
    func awaitsRestore(_ windowID: String) -> Bool {
        windowID == launchWindowID && !savedRegistryApplied
    }

    /// The launch window took the identity of the saved window it stands for (`adoptLaunchWindow`): what
    /// was asked for in it under its launch id (claims, sidebar rows and slots, a frame, a behind open)
    /// goes with it, so restore's reconcile places those workspaces in it, not in a new window under the old id.
    func launchWindowAdopted(from old: String, as new: String) {
        guard old != new else { return }
        for (id, window) in pendingClaims where window == old { pendingClaims[id] = new }
        for (id, placement) in pendingPlacements where placement.window == old { pendingPlacements[id]?.window = new }
        if let frame = pendingFrames.removeValue(forKey: old) { pendingFrames[new] = frame }
        if behindWindows.remove(old) != nil { behindWindows.insert(new) }
        PendingWorkspaceRows.shared.move(window: old, to: new)
    }

    /// Claims workspace `workspaceID`, which this app is about to create or
    /// just created, for window `windowID`: an open window takes and selects
    /// it; an unregistered id opens a new window with it (at `frame`). The
    /// placement happens when the daemon reports the workspace; a window
    /// never opens before that.
    /// An action run without view-change permission files it into an open
    /// window without showing it, or opens the new window behind.
    /// A claim for the launch window before restore stays pending even when the workspace is mirrored:
    /// the restore replaces the registry with the saved one and may rename the launch window
    /// (`awaitsRestore`), so only its reconcile places it.
    func claimNew(workspaceID: String, window windowID: String, frame: CGRect? = nil) {
        guard services.machines.workspace(id: workspaceID) != nil, !awaitsRestore(windowID) else {
            pendingClaims[workspaceID] = windowID
            if let frame, registry.value.window(windowID) == nil { pendingFrames[windowID] = frame }
            if !ActionRunScope.viewChangeAllowed() {
                // The launch window is open (it is on screen): filed there unshown, never sent behind.
                if registry.value.window(windowID)?.isOpen == true || awaitsRestore(windowID) { quietClaims.insert(workspaceID) } else { behindWindows.insert(windowID) }
            }
            return
        }
        // Already mirrored (the claim came after the delta): place it now.
        pendingClaims[workspaceID] = nil
        if let state = states[windowID], registry.value.window(windowID)?.isOpen == true {
            claim(workspaceID: workspaceID, in: state)
        } else {
            openWindow(id: windowID, workspaces: [workspaceID], frame: frame)
        }
    }
}
