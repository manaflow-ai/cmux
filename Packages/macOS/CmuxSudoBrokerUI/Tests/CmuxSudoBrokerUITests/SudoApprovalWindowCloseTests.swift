@testable import CmuxSudoBrokerUI
import AppKit
import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo approval window close", .serialized)
@MainActor
struct SudoApprovalWindowCloseTests {
    @Test("Closing the AppKit window leaves a request pending", arguments: [false, true])
    func closingDoesNotDeny(programmatic: Bool) async throws {
        let presentation = SudoApprovalPresentation(snapshot: SudoPendingRequest(
            request: SudoRequest(
                id: "close-test",
                reason: "test",
                requesterPid: 123,
                requesterCommand: "test",
                currentDirectory: "/tmp",
                createdAt: .now
            ),
            script: "echo test\n"
        ))
        var denialCount = 0
        var closeCount = 0
        let controller = SudoApprovalWindowController(
            presentation: presentation,
            approve: {},
            deny: { denialCount += 1 },
            didClose: { closeCount += 1 }
        )
        if programmatic {
            controller.dismiss()
        } else {
            controller.close()
        }
        // Let AppKit finish this close event, including work scheduled by its
        // delegate. No time-based delay is needed to observe the callback path.
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        #expect(closeCount == 1)
        #expect(denialCount == 0)
        #expect(presentation.canDecide)
    }
}
