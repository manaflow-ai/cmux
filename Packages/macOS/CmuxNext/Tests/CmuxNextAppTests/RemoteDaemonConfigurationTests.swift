@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Testing

/// p09-observability-116: every connection `DaemonService.start(remote:)` opens runs the heartbeat, so an SSH
/// bridge machine or a Cloud machine (a forwarded socket, no bridge child) gets its trace clock offset, as an
/// overlay server's bridged connection does.
@Suite struct RemoteDaemonConfigurationTests {
    @Test func aRemoteMachinesConnectionHeartbeatsWithOrWithoutABridgeChild() {
        let configuration = DaemonService.remoteConfiguration(retryWake: RetryWake(owner: "RemoteDaemonConfigurationTests"),
                                                              echoesPlacementShift: true, hangWatch: nil)
        #expect(configuration.remoteMachine)
        #expect(configuration.sessionEvents)
        #expect(configuration.echoesPlacementShift)
        #expect(configuration.heartbeats(DaemonEndpoint(socketPath: "/tmp/cmux-ssh-forward.sock")))
    }
}
