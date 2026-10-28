import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLaunch

// Creating workspaces and windows. A window exists only while it owns a workspace, so a new window is never opened
// empty: the workspace is claimed for its window before the create command is sent, and reconcile opens (or fills) that
// window in the same step that first mirrors the workspace, whichever of the command reply and the daemon delta comes
// first. A new window whose create waits longer opens with its claimed workspace two frames after the press and shows
// its creating state (`WindowContentWaits`, B7).
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

    /// New window with a new workspace. Returns the window id right away; the window opens when the daemon reports the
    /// workspace, or two frames after the press with its creating state (its wait, from the press: `contentWaits`).
    /// `holdingKeysFrom`: Cmd-Shift-N's window; keys typed there meanwhile go to the new page (cx-kql5h).
    @discardableResult
    func newWindow(frame: CGRect? = nil, holdingKeysFrom keyWindow: NSWindow? = nil) -> String {
        let windowID = UUID().uuidString.lowercased(), input = services.keyRouter.newTabInputCoordinator
        // cmux Classic Mode opens a terminal, not a page: no page would take the held keys.
        let keys = NewTabKind.terminalFirst(services) ? nil : input.beginIncoming(in: keyWindow, followsNewWindow: true)
        contentWaits.begin(windowID, reason: .newWindow, in: self)
        Task { [services] in
            let made = await createWorkspace(into: windowID, frame: frame, newTabPage: true, inputToken: keys)
            input.endIncoming(keys, pageMade: made != nil); withExtendedLifetime(services) {}
            if made == nil { contentWaits.createFailed(windowID, in: self) }
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

    /// `preferred` when that window is open, else a new window id.
    func targetWindow(preferring preferred: String?) -> String {
        if let preferred, registry.value.window(preferred)?.isOpen == true { return preferred }
        return UUID().uuidString.lowercased()
    }

    /// Claims workspace `workspaceID`, which this app is about to create or just created, for window `windowID`: an
    /// open window takes and selects it; an unregistered id opens a new window with it (at `frame`) when the daemon
    /// reports it, or at its wait's limit for a new window (`newWindow`). An action run without view-change permission
    /// files it into an open window without showing it, or opens the new window behind.
    func claimNew(workspaceID: String, window windowID: String, frame: CGRect? = nil) {
        guard services.machines.workspace(id: workspaceID) != nil else {
            pendingClaims[workspaceID] = windowID
            if let frame, registry.value.window(windowID) == nil { pendingFrames[windowID] = frame }
            if !ActionRunScope.viewChangeAllowed() {
                if registry.value.window(windowID)?.isOpen == true { quietClaims.insert(workspaceID) } else { behindWindows.insert(windowID) }
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

// A window's off-screen wait (B7) in this app's windows.
extension WindowContentWaits {
    /// Starts window `id`'s wait: at its limit the window shows its wait state and the bring-to-front asked meanwhile.
    /// A new window not opened yet (its create waits for the daemon) opens then with the workspace claimed for it.
    func begin(_ id: String, reason: Reason, in manager: WindowManager) {
        begin(id, reason: reason) { [weak manager] in
            guard let manager else { return true }
            if manager.registry.value.window(id) == nil, let claimed = manager.pendingClaims.first(where: { $0.value == id })?.key {
                manager.openWindow(id: id, workspaces: [claimed], frame: manager.pendingFrames.removeValue(forKey: id))
            }
            guard let controller = manager.controller(for: id) else { return false }
            guard let front = manager.awaitingContent.removeValue(forKey: id) else { return true }
            controller.showContentWait()
            manager.present(controller)
            if front { manager.bringToFront(controller) }
            return true
        }
    }

    /// New window `id`'s create failed: its wait ends, and the claim of a window opened for it goes, so reconcile
    /// closes that window (it never shows its creating state with no end).
    func createFailed(_ id: String, in manager: WindowManager) {
        end(id, .closed)
        let claims = manager.pendingClaims.filter { $0.value == id }.map(\.key)
        guard !claims.isEmpty, manager.registry.value.window(id) != nil else { return }
        for key in claims { manager.pendingClaims[key] = nil }
        manager.reconcileMembership()
    }
}
