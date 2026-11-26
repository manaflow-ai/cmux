import Testing
@testable import CmuxUpdaterCore

@Suite struct UpdateRelaunchBlockersTests {
    @Test func theWaitCapBoundsOnlyAutomaticInstalls() {
        let busy = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1, userInputActive: true)
        func relaunches(automatic: Bool, waited: Duration) -> Bool {
            (automatic ? busy : busy.forUserInstall).permitsRelaunch(
                automatic: automatic, waited: waited,
                daemonUnavailableFor: .zero, agentTimeout: .seconds(30 * 60),
                daemonUnavailableTimeout: .seconds(10 * 60), automaticWaitCap: .seconds(15 * 60))
        }

        #expect(!relaunches(automatic: true, waited: .seconds(15 * 60 - 2)))
        #expect(relaunches(automatic: true, waited: .seconds(15 * 60)))
        // A host that holds user installs keeps holding them for a running command.
        #expect(!relaunches(automatic: false, waited: .seconds(60 * 60)))
    }
}
