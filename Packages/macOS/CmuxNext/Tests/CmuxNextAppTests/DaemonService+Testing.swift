import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation

extension DaemonService {
    /// A service on a main-thread scheduler of its own (no pending-input check): the app builds
    /// one ``MainWorkScheduler`` at its composition root and passes it in; a test has no app.
    convenience init(machineID: String = "local") {
        self.init(machineID: machineID, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// A service on the test's `mainWork`, with a deadline placer on it and AppEvents of its own: the app passes
    /// its one of each (`AppServices.mainDeadlines`, `AppServices.appEvents`); a test has no app.
    convenience init(machineID: String = "local", mainWork: MainWorkScheduler) {
        self.init(machineID: machineID, mainWork: mainWork, deadlines: MainDeadlineScheduler(work: mainWork),
                  appEvents: AppEvents(center: NotificationCenter()))
    }
}
