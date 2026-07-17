#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct TaskComposerFailureMessageTests {
    @Test func invalidWorkingDirectoryUsesActionableLocalizedDefault() {
        let message = TaskComposerSheet.failureMessage(
            .invalidWorkingDirectory(hostDisplayName: "Test Mac")
        )

        #expect(message == "Choose an existing folder on that Mac.")
    }

    @Test func persistenceFailureExplainsSafeReservationFailure() {
        let message = TaskComposerSheet.failureMessage(
            .persistenceUnavailable(hostDisplayName: "Test Mac")
        )

        #expect(message == "The Mac could not safely reserve this task.")
    }

    @Test func localDraftPersistenceFailureExplainsHowToRecover() {
        #expect(
            TaskComposerSheet.draftPersistenceFailureMessage
                == "cmux couldn’t save this draft safely. Reopen the composer and try again."
        )
    }

    @Test func completedOperationExplainsHowToRecover() {
        let message = TaskComposerSheet.failureMessage(
            .alreadyCompleted(hostDisplayName: "Test Mac")
        )

        #expect(message == "The Mac already accepted this task. Refresh workspaces before trying again.")
    }

    @Test func completedOperationRequiresReconciliationBeforeStartAgain() {
        let snapshot = Self.snapshot(operationID: UUID())
        var recovery = TaskComposerCompletedOperationRecovery(submittedSnapshot: snapshot)

        #expect(recovery.phase == .refreshRequired)
        #expect(recovery.allowsStartAgain == false)
        recovery.recordReconciliationStillMissing()
        #expect(recovery.phase == .startAgainAvailable)
        #expect(recovery.allowsStartAgain)
        #expect(recovery.submittedSnapshot == snapshot)
    }

    @Test func startAgainUsesAFreshOperationIdentityWithoutChangingTheDraft() throws {
        let snapshot = Self.snapshot(operationID: UUID())
        var identity = MobileTaskSubmissionIdentity(
            id: snapshot.operationID,
            initialRequest: snapshot
        )

        identity.rotate()
        let retried = try #require(identity.resolveCurrentRequest { nil })

        #expect(retried.operationID != snapshot.operationID)
        #expect(retried.isRequestEquivalent(to: snapshot))
        #expect(retried.prompt == snapshot.prompt)
        #expect(retried.directory == snapshot.directory)
    }

    private static func snapshot(operationID: UUID) -> MobileTaskSubmissionSnapshot {
        MobileTaskSubmissionSnapshot(
            template: MobileTaskTemplate(
                name: "Codex",
                icon: "agent:codex",
                command: "codex -- \"$CMUX_TASK_PROMPT\""
            ),
            prompt: "Fix the flaky test",
            macDeviceID: "mac-1",
            directory: "~/Dev/cmux",
            didEditDirectory: true,
            operationID: operationID
        )
    }
}
#endif
