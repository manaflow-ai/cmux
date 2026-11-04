@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextServer
import Testing

/// The right sidebar's Cloud rows read their machine's server record and stage (cloud dogfood: three
/// paused machines spun forever next to their names while the Cloud page listed them as Paused).
@Suite struct MachineSectionServerStateTests {
    @Test func aPausedMachineReadsPausedAndAResumeKeepsASpinner() {
        #expect(Self.state(.paused, stage: .paused(idle: true)) == .paused)
        #expect(Self.state(.paused, stage: .paused(idle: false)) == .paused)
        // An attach or a click resuming it: the link is starting or up.
        #expect(Self.state(.paused, stage: .booting) == .resuming)
        #expect(Self.state(.paused, stage: .connecting) == .resuming)
        #expect(Self.state(.paused, stage: .failed("resume refused")) == .failed)
    }

    @Test func settledStatesReadInWordsAndLiveOnesFollowTheLink() {
        #expect(Self.state(.failed, stage: .failed("x")) == .failed)
        #expect(Self.state(.destroyed, stage: .booting) == .deleted)
        for status in [CloudMachine.Status.running, .provisioning, .unknown] {
            for stage in [CloudMachineStage.booting, .connecting, .ready] {
                #expect(Self.state(status, stage: stage) == nil)
            }
        }
    }

    /// The stage a paused machine with no attach reaches, from the same input the Cloud page reads,
    /// makes a row with no spinner even while its daemon store sits in `.connecting`.
    @Test func aPausedMachineWhoseDaemonSitsConnectingShowsNoSpinner() {
        let stage = CloudMachineStageInput(creation: nil, machineStatus: .paused, pauseReason: .user).stage
        let row = MachineSectionRow(id: "vm-1", name: "zesty", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true,
                                    serverState: Self.state(.paused, stage: stage))
        #expect(row.serverState == .paused)
        #expect(!row.isConnecting)
        #expect(row.stateText == MachineServerState.paused.text)
    }

    /// The row's reading of a Cloud machine, as `MachineSectionRow.rows` passes it: the server status
    /// and whether the app's stage for the machine is paused or failed.
    private static func state(_ status: CloudMachine.Status, stage: CloudMachineStage) -> MachineServerState? {
        .cloud(status, stagePaused: stage.isPaused, stageFailed: stage.failure != nil)
    }
}
