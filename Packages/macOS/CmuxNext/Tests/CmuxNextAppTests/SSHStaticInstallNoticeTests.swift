@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// The person's own `~/.cmux/bin/cmux` is older than the app's build and a newer one waits staged
/// beside it (nothing on the machine was restarted): the connected machine's header says so,
/// and an install or connect failure still comes first.
@Suite struct SSHStaticInstallNoticeTests {
    @MainActor private func session() throws -> SSHMachineSession {
        let host = try SSHHost(destination: SSHDestination(parsing: "orchestrator.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/static-install-notice-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        session.linkStatus = .connected
        return session
    }

    @Test @MainActor func aConnectedMachineWithAStagedBuildSaysSo() throws {
        let session = try session()
        #expect(RemoteStrings.detail(session) == nil, "nothing staged: nothing to say")
        session.staticInstallStaged = true
        #expect(RemoteStrings.detail(session) == RemoteStrings.staticInstallStaged)
    }

    @Test @MainActor func aFailureComesBeforeTheStagedNotice() throws {
        let session = try session()
        session.staticInstallStaged = true
        session.lastError = "SSH failed: timed out"
        #expect(RemoteStrings.detail(session) == "SSH failed: timed out")
    }
}
