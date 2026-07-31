import Testing
@testable import CmuxTerminalCore

@Suite struct TerminalPromptInputLedgerTests {
    @Test func lateHumanHookDoesNotClearNewerTyping() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(maySubmitPrompt: false)
        ledger.recordHumanInput(maySubmitPrompt: true)
        ledger.recordHumanInput(maySubmitPrompt: false)

        #expect(ledger.confirmNextSubmission() == .human)
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func programmaticHookNeverClearsHumanTyping() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(hookRecording: .alreadyRecorded)
        ledger.recordHumanInput(maySubmitPrompt: false)

        #expect(
            ledger.confirmNextSubmission()
                == .programmatic(.alreadyRecorded)
        )
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func programmaticHookCarriesDeferredRecordingOwnership() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            hookRecording: .recordWhenConfirmed
        )

        #expect(
            ledger.confirmNextSubmission()
                == .programmatic(.recordWhenConfirmed)
        )
    }

    @Test func matchedHumanSubmissionClearsItsGeneration() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(maySubmitPrompt: false)
        ledger.recordHumanInput(maySubmitPrompt: true)

        #expect(ledger.confirmNextSubmission() == .human)
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func newAgentScopeDiscardsShellOrPreviousAgentInput() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(maySubmitPrompt: false)
        ledger.recordHumanInput(maySubmitPrompt: true)

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(!ledger.hasUnconfirmedHumanInput)
        #expect(ledger.confirmNextSubmission() == .unmatched)
    }

    @Test func unchangedAgentScopePreservesItsHumanDraft() {
        var ledger = TerminalPromptInputLedger()
        ledger.synchronizeAgentScope("agentPIDKey:codex.session")
        ledger.recordHumanInput(maySubmitPrompt: false)

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(ledger.hasUnconfirmedHumanInput)
    }
}
