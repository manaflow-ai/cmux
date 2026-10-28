import CmuxNextDaemon
import CmuxNextWakeups
import os

/// A tab the store just created, once its tree has it. The creation reply can come before the
/// tree mirrors the tab, and an action on the tab then is refused ("no tab"): [+] New tab's page
/// stayed in the chat's pane because its move ran in that gap (cx-65br).
enum TabMirror {
    typealias Locate = @MainActor (String) -> (pane: PaneID, daemon: DaemonService)?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.tab-mirror")
    private static let owner = "TabMirror.reaches"

    /// A creation reply is not yet a usable placement target until its tree has the tab.
    @MainActor static func performWhenReached(_ key: String, in locate: @escaping Locate, perform: @MainActor () -> Void) async {
        guard await reaches(key, in: locate), !Task.isCancelled else { return }
        perform()
    }

    /// Whether `locate` finds tab `key` within 10 s (at once when it already does); logs when not.
    /// One keyed wait (recipe R-wait): a ServiceObservation of the lookup on `mainWork` settles it, and
    /// its timeout is a deadline on the scheduler's one wake-up queue, so nothing polls and no Task
    /// waits per change (Chromium signals a waiter from the change itself: `base/one_shot_event.h`).
    static func reaches(_ key: String, in locate: @escaping Locate, on mainWork: MainWorkScheduler) async -> Bool {
        if locate(key) != nil { return true }
        let waiters = KeyedWaiters<String, Void>(deadlines: AlignedWakeups(queue: mainWork.wakeUps), deadlineOwner: owner)
        let lookup = ServiceObservation(.visible, owner: owner, on: mainWork) { locate(key) != nil } apply: { [weak waiters] found in
            if found { waiters?.settle(key, with: ()) }
        }
        let reached = await waiters.value(of: key, now: (), timeout: .seconds(10)) { _ in locate(key) != nil ? true : nil } ?? false
        lookup.cancel()
        if !reached { logger.error("tab \(key, privacy: .public) did not reach the store's tree within 10 s") }
        return reached
    }
}
