import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
@testable import CmuxNextApp

// The machine sessions on a test's own main-thread scheduler, with a deadline placer on it and AppEvents of their
// own: the app passes the local daemon's one of each (`DaemonService.deadlines`, `DaemonService.appEvents`); a test
// has no app.

extension SSHMachineSession {
    convenience init(host: SSHHost, binary: URL, paths: SSHPaths, environment: @escaping @Sendable () async -> [String: String],
                     mainWork: MainWorkScheduler) {
        self.init(host: host, binary: binary, paths: paths, environment: environment, mainWork: mainWork,
                  deadlines: MainDeadlineScheduler(work: mainWork), appEvents: AppEvents(center: NotificationCenter()))
    }
}

extension ServerMachineSession {
    convenience init(reach: ServerReach, binary: URL?, paths: SSHPaths, environment: @escaping @Sendable () async -> [String: String],
                     localIdentity: @escaping @MainActor () -> DaemonIdentity?, mainWork: MainWorkScheduler) {
        self.init(reach: reach, binary: binary, paths: paths, environment: environment, localIdentity: localIdentity,
                  mainWork: mainWork, deadlines: MainDeadlineScheduler(work: mainWork), appEvents: AppEvents(center: NotificationCenter()))
    }
}

extension CloudMachineSession {
    convenience init(machine: CloudMachine, link: CloudMachineLink, mainWork: MainWorkScheduler, work: BackgroundWork) {
        self.init(machine: machine, link: link, mainWork: mainWork, deadlines: MainDeadlineScheduler(work: mainWork),
                  appEvents: AppEvents(center: NotificationCenter()), work: work)
    }
}
