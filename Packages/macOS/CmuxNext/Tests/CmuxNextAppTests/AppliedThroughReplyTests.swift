import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// The service side of read-your-writes without a daemon (`DaemonService.appliedThroughReply(on:after:)` and
/// `appliedThroughSyncBarrier()`): a wait on a connection that is not the service's proves nothing about the
/// command, and with no current connection to take a barrier on it is not held, at once; a barrier that
/// cannot read its writes throws. The cases with a daemon are ``AppliedThroughRecoveryTests``.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppliedThroughReplyTests {
    @Test func aConnectionThatIsNotTheServicesIsNotHeldWithoutACurrentOne() async {
        let daemon = DaemonService()
        let other = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/tmp/cna-reply-\(UUID().uuidString.prefix(8)).sock"))
        #expect(await daemon.appliedThroughReply(on: other, after: "test") == .connectionChanged)
    }

    @Test func theSyncBarrierWithoutAConnectionThrows() async {
        let daemon = DaemonService()
        await #expect(throws: DaemonError.self) { try await daemon.appliedThroughSyncBarrier() }
    }
}
