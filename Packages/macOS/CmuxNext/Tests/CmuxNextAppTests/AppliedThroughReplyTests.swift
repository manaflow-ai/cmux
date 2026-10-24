import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// The service side of read-your-writes (`DaemonService.appliedThroughReply(on:after:)` and
/// `appliedThroughSyncBarrier()`): a wait on a connection that is not the service's proves nothing about the
/// command, so it is not held, at once, and never waits on another connection's sequences; a barrier that
/// cannot read its writes throws. A command that went through but cannot be shown answers `unavailable` and
/// may have applied, never success.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppliedThroughReplyTests {
    @Test func aConnectionThatIsNotTheServicesIsNotHeldAtOnce() async {
        let daemon = DaemonService()
        let other = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/tmp/cna-reply-\(UUID().uuidString.prefix(8)).sock"))
        #expect(await daemon.appliedThroughReply(on: other, after: "test") == .connectionChanged)
    }

    @Test func theSyncBarrierWithoutAConnectionThrows() async {
        let daemon = DaemonService()
        await #expect(throws: DaemonError.self) { try await daemon.appliedThroughSyncBarrier() }
    }

    @Test func aResultTheStoreCannotShowIsAnUnavailableFailureThatMayHaveApplied() {
        let failure = ActionWorkFailure.resultNotShown
        #expect(failure.refusal == .unavailable)
        #expect(failure.mayHaveApplied)
        #expect(failure.message == RefusalStrings.resultNotShown)
        #expect(!failure.message.isEmpty)
    }
}
