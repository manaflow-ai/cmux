@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// A Cloud start that can't go on after its machine was made deletes that machine; one whose Retry reuses the
/// machine keeps it. Leo, 2026-11-10, on a start from ~/Projects whose copy failed with the machine left running:
/// "did you guys not test these".
@Suite struct CloudStartChatStrandedTests {
    @Test func onlyAFailureWithAWorkingRetryKeepsTheMachine() {
        #expect(!CloudStartChat.strands(CloudMoveFailure(message: "the machine stopped answering", retry: .move(machineID: "m1"))))
        #expect(CloudStartChat.strands(CloudMoveFailure(message: "the account changed")))
        #expect(CloudStartChat.strands(CloudMoveCLI.StartChatPreflightRefusal(message: "too big", folder: "~/Projects", machineMade: true)))
        #expect(CloudStartChat.strands(CloudMoveFolder.Gone()))
        // A cancel is the start's own end (the page left): another try reuses the machine.
        #expect(!CloudStartChat.strands(CancellationError()))
    }
}
