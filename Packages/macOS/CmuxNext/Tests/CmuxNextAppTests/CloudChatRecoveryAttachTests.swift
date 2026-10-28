import CmuxNextAgentPane
@testable import CmuxNextApp
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
    /// click. The refresh runs before the read, so the live machine is attached, never resumed.
    @Test func aMachineThatTurnedLiveSinceTheRecoveryReadIsNotResumed() async {
        var status: CloudMachine.Status = .paused
        var steps: [String] = []
        let ran = await AgentPaneCloudMachines.recoveryAttach(
            refresh: { steps.append("refresh"); status = .running; return true },
            machine: { steps.append("read \(status.rawValue)"); return (status, false) },
            attach: { steps.append("attach \(status.rawValue)") }
        )
        #expect(ran)
        #expect(steps == ["refresh", "read running", "attach running"])
        #expect(AgentPaneCloudMachines.recoveryAttach(fresh: true, status: status, connected: false) != .resume)
    }

    @Test func aLiveConnectedMachineIsNotTouched() async {
        var attached = false
        let ran = await AgentPaneCloudMachines.recoveryAttach(
            refresh: { true }, machine: { (.running, true) }, attach: { attached = true })
        #expect(ran && !attached)
    }

    @Test func aFailedRefreshRunsNothing() async {
        var attached = false
        let ran = await AgentPaneCloudMachines.recoveryAttach(
            refresh: { false }, machine: { (.paused, false) }, attach: { attached = true })
        #expect(!ran && !attached)
    }
}
