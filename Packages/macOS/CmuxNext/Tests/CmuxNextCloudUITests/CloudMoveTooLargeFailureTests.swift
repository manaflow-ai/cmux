import CmuxNextCloud
@testable import CmuxNextCloudUI
import Testing

/// A copy refused as past its limits (`copy.too_large`) offers no Retry, which could only fail the same way; a Cloud
/// start then deletes the machine it made (CloudStartStranded). Another copy failure keeps its Retry.
@Suite @MainActor struct CloudMoveTooLargeFailureTests {
    @Test func aTooLargeCopyHasNoRetry() {
        let tooLarge = CloudMoveCLI.Answer(ok: false, errorCode: "copy.too_large", error: "~/Projects is too big to copy")
        #expect(CloudMoveFailure.syncing(tooLarge, machine: "paint-dev", retry: .move(machineID: "m1")).retry == nil)
        let other = CloudMoveCLI.Answer(ok: false, errorCode: "sync.failed", error: "the machine stopped answering")
        #expect(CloudMoveFailure.syncing(other, machine: "paint-dev", retry: .move(machineID: "m1")).retry != nil)
    }
}
