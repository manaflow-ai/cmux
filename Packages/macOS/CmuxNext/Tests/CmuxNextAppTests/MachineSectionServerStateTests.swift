@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextServer
import Testing

/// The right sidebar's Cloud rows read their machine's server record and stage (cloud dogfood: three
/// paused machines spun forever next to their names while the Cloud page listed them as Paused).
@Suite struct MachineSectionServerStateTests {
    @Test func aPausedMachineReadsPausedAndAResumeKeepsASpinner() {
        #expect(MachineSectionRow.cloudServerState(.paused, stage: .paused(idle: true)) == .paused)
        #expect(MachineSectionRow.cloudServerState(.paused, stage: .paused(idle: false)) == .paused)
        // An attach or a click resuming it: the link is starting or up.
        #expect(MachineSectionRow.cloudServerState(.paused, stage: .booting) == .resuming)
        #expect(MachineSectionRow.cloudServerState(.paused, stage: .connecting) == .resuming)
        #expect(MachineSectionRow.cloudServerState(.paused, stage: .failed("resume refused")) == .failed)
    }

    @Test func settledStatesReadInWordsAndLiveOnesFollowTheLink() {
        #expect(MachineSectionRow.cloudServerState(.failed, stage: .failed("x")) == .failed)
        #expect(MachineSectionRow.cloudServerState(.destroyed, stage: .booting) == .deleted)
        for status in [CloudMachine.Status.running, .provisioning, .unknown] {
            for stage in [CloudMachineStage.booting, .connecting, .ready] {
                #expect(MachineSectionRow.cloudServerState(status, stage: stage) == nil)
            }
        }
    }

    /// The stage a paused machine with no attach reaches, from the same input the Cloud page reads,
    /// makes a row with no spinner even while its daemon store sits in `.connecting`.
    @Test func aPausedMachineWhoseDaemonSitsConnectingShowsNoSpinner() {
        let stage = CloudMachineStageInput(creation: nil, machineStatus: .paused, pauseReason: .user).stage
        let row = MachineSectionRow(id: "vm-1", name: "zesty", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true,
                                    serverState: MachineSectionRow.cloudServerState(.paused, stage: stage))
        #expect(row.serverState == .paused)
        #expect(!row.isConnecting)
        #expect(row.stateText == MachineServerState.paused.text)
    }
}
