import CmuxFoundation
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Native SSH ControlMaster adoption handoff")
struct NativeSSHControlMasterAdoptionHandoffTests {
    @MainActor
    @Test(
        "Adoption rejects paths that are not exact resolved cmux sockets",
        arguments: [
            "",
            " /tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567",
            "/tmp/cmux-ssh-501-%C",
            "/tmp/cmux-ssh-502-0123456789abcdef0123456789abcdef01234567",
            "~/.ssh/custom-0123456789abcdef0123456789abcdef01234567",
        ]
    )
    func adoptionRejectsUnownedPath(controlPath: String) {
        let registry =
            PermissiveNativeSSHControlMasterOwnershipRegistry()
        let broker = NativeSSHConnectionBroker(
            sharingOptions: SSHConnectionSharingOptions(userID: 501),
            clock: RecordingImmediateClock(),
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in },
            controlMasterOwnershipRegistry: registry
        )

        #expect(broker.beginControlMasterAdoption(
            controlPath: controlPath,
            ownerWorkspaceID: UUID()
        ) == nil)
        #expect(registry.retainedControlPaths.isEmpty)
    }

    @Test("An unconsumed handoff expires and releases ownership once")
    func unconsumedHandoffExpires() async {
        let clock = ManualBrokerClock()
        let recorder = SynchronousEventRecorder()
        let (releases, releaseContinuation) =
            AsyncStream<Void>.makeStream()
        let handoff = NativeSSHControlMasterAdoptionHandoff(
            controlPath: "/tmp/cmux-ssh-501-test",
            lease: NativeSSHControlMasterLeaseIdentity(
                ownerWorkspaceID: UUID(),
                generation: UUID()
            ),
            clock: clock,
            expirationMilliseconds: 10,
            releaseHandler: {
                recorder.record()
                releaseContinuation.yield()
                releaseContinuation.finish()
            }
        )

        #expect(await clock.nextRequestedDelay() == 10)
        var releaseIterator = releases.makeAsyncIterator()
        await clock.resumeNextSleep()
        #expect(await releaseIterator.next() != nil)
        #expect(recorder.count == 1)

        handoff.release()
        #expect(recorder.count == 1)
    }
}
