@testable import CmuxNextAgentPane
import CmuxNextCloud
import Testing

/// Resume machine on an unavailable Cloud chat decides on a fresh read of the machine: the
/// recovery list that offered it may be a minute old (review of cmux#27031).
@MainActor
struct CloudChatRecoveryAttachTests {
    @Test func decidesOnTheFreshStatus() {
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: .paused, connected: false) == .resume)
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: .running, connected: false) == .connect)
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: .running, connected: true) == .connected)
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: .provisioning, connected: false) == .connect)
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: .destroyed, connected: false) == .refuse)
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: .failed, connected: false) == .refuse)
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: nil, connected: false) == .refuse)
        // A refresh that failed or was superseded settles nothing, even for a cached paused row.
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: false, status: .paused, connected: false) == .refuse)
    }

    /// The race: the card offered Resume on a paused row, and the machine turned live before the
    /// click. The refresh runs before the read, so the live machine is connected, never resumed
    /// (a legacy machine's `attach` would do nothing for it: second review of cmux#27031).
    @Test func aMachineThatTurnedLiveSinceTheRecoveryReadIsConnectedNotResumed() async {
        var status: CloudMachine.Status = .paused
        var steps: [String] = []
        let ran = await AgentPaneCloudMachines.recoveryAttach(
            refresh: { steps.append("refresh"); status = .running; return true },
            machine: { steps.append("read \(status.rawValue)"); return (status, false) },
            resume: { steps.append("resume") },
            connect: { steps.append("connect \(status.rawValue)") }
        )
        #expect(ran)
        #expect(steps == ["refresh", "read running", "connect running"])
    }

    @Test func aPausedMachineIsResumed() async {
        var steps: [String] = []
        let ran = await AgentPaneCloudMachines.recoveryAttach(
            refresh: { true }, machine: { (.paused, false) },
            resume: { steps.append("resume") }, connect: { steps.append("connect") })
        #expect(ran && steps == ["resume"])
    }

    @Test func aLiveConnectedMachineIsNotTouched() async {
        var steps: [String] = []
        let ran = await AgentPaneCloudMachines.recoveryAttach(
            refresh: { true }, machine: { (.running, true) },
            resume: { steps.append("resume") }, connect: { steps.append("connect") })
        #expect(ran && steps.isEmpty)
    }

    @Test func aFailedRefreshRunsNothing() async {
        var steps: [String] = []
        let ran = await AgentPaneCloudMachines.recoveryAttach(
            refresh: { false }, machine: { (.paused, false) },
            resume: { steps.append("resume") }, connect: { steps.append("connect") })
        #expect(!ran && steps.isEmpty)
    }
}
