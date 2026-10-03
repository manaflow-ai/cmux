import AppKit
import CmuxNextActions
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
                         frame: CGRect? = nil) async -> String? {
        let daemon = daemon ?? services.daemon
        do {
            return try await createWorkspace(WorkspaceSpawn(cwd: cwd), on: daemon, into: windowID, frame: frame)
        } catch {
            daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// New workspace in `state`'s window when it is open, else in a new
    /// window (the app has no open window: Dock, CLI, menu).
    /// `slot` places it in that window's sidebar once it is reported.
    func newWorkspace(in state: WindowState?, on daemon: DaemonService? = nil, at slot: WorkspaceSlot? = nil) {
        let target = targetWindow(preferring: state?.id)
        var spawn = WorkspaceSpawn()
        spawn.slot = slot
        Task {
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
    func newWindow(frame: CGRect? = nil) -> String {
        let windowID = UUID().uuidString.lowercased()
        Task { await createWorkspace(into: windowID, frame: frame) }
        return windowID
    }

    /// Dock click, Show cmux: the last closed window comes back with its
    /// workspaces; with none registered, a new window with a new workspace.
    func reopenOrCreateWindow() {
        if !reopenClosedWindow() { newWindow() }
    }

    /// `preferred` when that window is open, else a new window id.
    func targetWindow(preferring preferred: String?) -> String {
        if let preferred, registry.value.window(preferred)?.isOpen == true { return preferred }
        return UUID().uuidString.lowercased()
    }

    /// Claims workspace `workspaceID`, which this app is about to create or
    /// just created, for window `windowID`: an open window takes and selects
    /// it; an unregistered id opens a new window with it (at `frame`). The
    /// placement happens when the daemon reports the workspace; a window
    /// never opens before that.
    /// An action run without view-change permission files it into an open
    /// window without showing it, or opens the new window behind.
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
