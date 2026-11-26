import CmuxNextCloud
@testable import CmuxNextCloudUI
import Testing

/// The kill-mid-move drills' cases read as plain reasons, each with its Retry, and never end the source chat
/// (that is the CLI's; these are its answers): the machine was restarting and the CLI gave the chat back at its
/// deadline (`agent_transfer.unavailable`, cmux#54582), and a machine too old for a file of the chat (the CLI's
/// `machine_outdated`, cmux#54649) asks for the machine's update, never the raw `transfer.path` line.
@Suite @MainActor struct CloudMoveKillMidMoveFailureTests {
    @Test func aRestartingMachineSaysSoAndOffersRetry() {
        let toCloud = CloudMoveCLI.Answer(ok: false, errorCode: "agent_transfer.unavailable", error: "this daemon has no acpmux or host to move chats with", side: "target")
        let moving = CloudMoveFailure.moving(toCloud, machine: "paint-dev", retry: .move(machineID: "m1"))
        #expect(moving.message == CloudMoveStrings.restarting("paint-dev"))
        #expect(moving.retry != nil)
        let back = CloudMoveCLI.Answer(ok: false, errorCode: "agent_transfer.unavailable", error: "this daemon has no acpmux or host to move chats with", side: "source")
        let bringing = CloudMoveFailure.bringingBack(back, machine: "paint-dev", retry: .move(machineID: "m1"))
        #expect(bringing.message == CloudMoveStrings.restarting("paint-dev"))
        #expect(bringing.retry != nil)
    }

    /// The drills' frozen source showed "sync_failed: the folder's last changes: sync_failed: the machine
    /// did not answer for N s"; a Retry then moved the chat in 5.9 s.
    @Test func lastChangesThatDidNotCopyReadPlainlyAndOfferRetry() {
        let detail = "the folder's last changes: the machine did not answer for 30 s"
        let moving = CloudMoveFailure.moving(CloudMoveCLI.Answer(ok: false, errorCode: "sync_failed", error: detail, side: "target"),
                                             machine: "paint-dev", retry: .move(machineID: "m1"))
        #expect(moving.message == CloudMoveStrings.lastChangesFailed)
        #expect(moving.retry != nil)
        #expect(!moving.message.contains("sync_failed"))
        let back = CloudMoveFailure.bringingBack(CloudMoveCLI.Answer(ok: false, errorCode: "sync_failed", error: detail, side: "source"),
                                                 machine: "paint-dev", retry: .move(machineID: "m1"))
        #expect(back.message == CloudMoveStrings.lastChangesFailed)
        #expect(back.retry != nil)
    }

    @Test func aMachineTooOldForAFileAsksForItsUpdate() {
        let answer = CloudMoveCLI.Answer(ok: false, errorCode: CloudMoveStrings.outdatedCode,
                                         error: "the machine runs an older cmux-tui that refused a file of this chat; update the machine", side: "target")
        let failure = CloudMoveFailure.moving(answer, machine: "paint-dev", retry: .move(machineID: "m1"))
        #expect(failure.message == CloudMoveStrings.outdatedMachine("paint-dev"))
        #expect(!failure.message.contains("transfer.path"))
    }
}
