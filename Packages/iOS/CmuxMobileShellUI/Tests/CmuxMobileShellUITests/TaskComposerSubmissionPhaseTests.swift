#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerSubmissionPhaseTests {
    @Test func idleAllowsAnInitialSubmissionWithoutLockingTheDraft() {
        let phase = TaskComposerSubmissionPhase.idle

        #expect(phase.allowsSubmission)
        #expect(!phase.offersRetry)
        #expect(!phase.disablesRequestEditing)
        #expect(!phase.showsProgress)
        #expect(!phase.locksDismissal)
    }

    @Test func retryReadyOffersAnActionableRetryWithoutLockingTheDraft() {
        let phase = TaskComposerSubmissionPhase.retryReady

        #expect(phase.allowsSubmission)
        #expect(phase.offersRetry)
        #expect(!phase.disablesRequestEditing)
        #expect(!phase.showsProgress)
        #expect(!phase.locksDismissal)
    }

    @Test func preparingShowsProgressAndLocksOnlyRequestEditing() {
        let phase = TaskComposerSubmissionPhase.preparing

        #expect(!phase.allowsSubmission)
        #expect(!phase.offersRetry)
        #expect(phase.disablesRequestEditing)
        #expect(phase.showsProgress)
        #expect(!phase.locksDismissal)
    }

    @Test func committedLocksEditingAndDismissalWhileShowingProgress() {
        let phase = TaskComposerSubmissionPhase.committed

        #expect(!phase.allowsSubmission)
        #expect(!phase.offersRetry)
        #expect(phase.disablesRequestEditing)
        #expect(phase.showsProgress)
        #expect(phase.locksDismissal)
    }
}
#endif
