import AppKit

// Parked workspaces (plans/cmux-next/tab-lifecycle.md): the workspaces this window showed most recently
// (`parkedCapacity`) stay mounted and paused, so a switch back swaps its view in within the frame.
extension WindowController {
    /// The shown workspace, then the parked ones from the most recently shown, each with its theme scope.
    var mountedContents: [WorkspaceContentController] {
        (content.map { [$0] } ?? []) + parked.values.sorted { $0.parkedSerial > $1.parkedSerial }
    }

    /// Critical memory pressure: the parked workspaces leave (views, panes, observations; their
    /// terminal surfaces already left the warm set) and mount again when shown, with their
    /// view-only state (strip and screen bar scroll) reset. The one under a top page stays: it is
    /// this window's workspace. So do the ones on screen beside the shown one (`sidebar.multiView`).
    func releaseParked() {
        for (id, controller) in parked where (content != nil || id != state.workspaceID) && state.viewSet?.contains(id) != true {
            parked[id] = nil
            controller.teardown()
        }
    }

    /// The most workspaces a window keeps mounted besides the shown one: the recently used set a person moves
    /// between, each a one-frame swap. Lawrence 2026-10-21 (workspace switch speed of light): every workspace a
    /// window had shown stayed mounted, its hidden view tree, Chromium child windows and tree observation included,
    /// and a switch at 150 workspaces spent 36 ms (p50) in AppKit's layer-tree build and window-server ordering
    /// over all of them. Older ones leave as `releaseParked` does and mount again when shown.
    static let parkedCapacity = 8

    func park(_ controller: WorkspaceContentController) {
        parkSerial &+= 1
        controller.park(serial: parkSerial)
        parked[controller.workspace.id] = controller
        evictParked(keeping: Self.parkedCapacity)
    }

    /// Tears down the least recently shown parked workspaces past `capacity` (O(parked), bounded). The one under a
    /// top page and the ones on screen beside the shown one (`sidebar.multiView`) stay, as in `releaseParked`.
    func evictParked(keeping capacity: Int) {
        guard parked.count > capacity else { return }
        let evictable = parked.filter { id, _ in (content != nil || id != state.workspaceID) && state.viewSet?.contains(id) != true }
        for (id, controller) in evictable.sorted(by: { $0.value.parkedSerial < $1.value.parkedSerial }).prefix(parked.count - capacity) {
            parked[id] = nil
            controller.teardown()
        }
    }
}
