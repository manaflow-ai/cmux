import AppKit
import CmuxNextHibernation

// Parked workspaces (plans/cmux-next/tab-lifecycle.md): every workspace this window showed stays mounted and
// paused, so a switch back swaps its view in within the frame.
extension WindowController {
    /// The shown workspace, then the parked ones from the most recently shown, each with its theme scope.
    var mountedContents: [WorkspaceContentController] {
        (content.map { [$0] } ?? []) + parked.values.sorted { $0.parkedSerial > $1.parkedSerial }
    }

    func park(_ controller: WorkspaceContentController) {
        parkSerial &+= 1
        controller.park(serial: parkSerial)
        parked[controller.workspace.id] = controller
    }
}

// Critical memory pressure releases parked workspaces one per frame (`ParkedWorkspaceRelease`): each
// leaves (views, panes, observations; its terminal surfaces already left the warm set) and mounts again
// when shown, with its view-only state (strip and screen bar scroll) reset.
extension WindowController: ParkedWorkspaceHost {
    var showsOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// The one under a top page stays: it is this window's workspace. So do the ones on screen beside
    /// the shown one (`sidebar.multiView`).
    var oldestReleasableParked: (id: String, serial: UInt64)? {
        var oldest: (id: String, serial: UInt64)?
        for (id, controller) in parked where isReleasable(id) {
            if let current = oldest, current.serial <= controller.parkedSerial { continue }
            oldest = (id, controller.parkedSerial)
        }
        return oldest
    }

    func releaseParked(_ id: String) {
        guard isReleasable(id), let controller = parked.removeValue(forKey: id) else { return }
        controller.teardown()
    }

    private func isReleasable(_ id: String) -> Bool {
        (content != nil || id != state.workspaceID) && state.viewSet?.contains(id) != true
    }
}
