import CmuxNextDaemonService
import CmuxNextWakeups

extension DaemonService {
    /// A service on a main-thread scheduler of its own (no pending-input check): the app builds
    /// one ``MainWorkScheduler`` at its composition root and passes it in; a test has no app.
    convenience init(machineID: String = "local") {
        self.init(machineID: machineID, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }
}
