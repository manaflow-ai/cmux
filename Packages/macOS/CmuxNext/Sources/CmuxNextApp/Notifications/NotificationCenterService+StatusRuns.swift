import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// Finished `cmux status run` notifications (`status.runNotify*`).
extension NotificationCenterService {
    /// The notices for the runs that finished since `tracker`'s last look.
    func statusRunNotices(in store: DaemonStore, tracker: inout FinishedStatusRunTracker,
                          behavior: StatusBehaviorSettings = DesignSettings.shared.statusBehavior,
                          visibility: ((LocatedTab) -> TerminalVisibility)? = nil) -> [StatusRunNotice] {
        []
    }
}
