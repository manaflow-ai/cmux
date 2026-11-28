import CmuxNextWakeups
import Foundation

// `sidebar.relativeTimestamps` (off by default): rows read `5m`, `2h`, so their labels age while nothing else
// changes. One deadline per list, armed only while relative times show (`SidebarRelativeTimesTick`): a quiet
// list reloads once as a label turns, never on a fixed beat. With the setting off nothing is scheduled.
extension SidebarListView {
    /// Arms (or drops) the next relative-time reload after a reload.
    func scheduleRelativeTimesTick() {
        guard model.showsTimestamps, model.relativeTimestamps,
              let delay = SidebarRelativeTimesTick.delay(workspaces.values.lazy.compactMap(\.rowAge), now: Date())
        else {
            relativeTimesTick.cancel()
            return
        }
        relativeTimesTick.schedule(after: delay) { @MainActor [weak self] in self?.reload(animated: false) }
    }
}
