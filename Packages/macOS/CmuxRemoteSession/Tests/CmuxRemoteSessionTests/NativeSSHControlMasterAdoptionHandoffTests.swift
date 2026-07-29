import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Native SSH ControlMaster adoption handoff")
struct NativeSSHControlMasterAdoptionHandoffTests {
    @Test("An unconsumed handoff expires and releases ownership once")
    func unconsumedHandoffExpires() async {
        let clock = ManualBrokerClock()
        let recorder = ResetEventRecorder()
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
            }
        )

        #expect(await clock.nextRequestedDelay() == 10)
        await clock.resumeNextSleep()
        await Task.yield()
        #expect(recorder.count == 1)

        handoff.release()
        #expect(recorder.count == 1)
    }
}
