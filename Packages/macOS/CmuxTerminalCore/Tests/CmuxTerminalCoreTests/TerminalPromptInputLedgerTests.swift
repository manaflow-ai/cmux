import Testing
@testable import CmuxTerminalCore

@Suite struct TerminalPromptInputLedgerTests {
    @Test func submitCapableReturnStaysBusyUntilItsHookArrives() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(maySubmitPrompt: false)

        ledger.recordHumanInput(maySubmitPrompt: true)

        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(ledger.confirmSubmission(message: "human prompt") == .human)
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func lateHumanHookDoesNotClearNewerTyping() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(maySubmitPrompt: false)
        ledger.recordHumanInput(maySubmitPrompt: true)
        ledger.recordHumanInput(maySubmitPrompt: false)

        #expect(ledger.confirmSubmission(message: "first prompt") == .human)
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func programmaticHookMatchNeverClearsNewerHumanTyping() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            message: "review this",
            source: "workspace.agent_submit"
        )
        ledger.recordHumanInput(maySubmitPrompt: false)

        #expect(
            ledger.confirmSubmission(message: "review this")
                == .programmatic(source: "workspace.agent_submit")
        )
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func unrelatedHookDoesNotConsumeProgrammaticRecord() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            message: "programmatic prompt",
            source: "workspace.agent_submit"
        )

        #expect(
            ledger.confirmSubmission(message: "human prompt")
                == .unmatched
        )
        #expect(
            ledger.confirmSubmission(message: "programmatic prompt")
                == .programmatic(source: "workspace.agent_submit")
        )
    }

    @Test func unmatchedProgrammaticBoundaryBlocksLaterHumanConfirmation() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            message: "programmatic prompt",
            source: "workspace.agent_submit"
        )
        ledger.recordHumanInput(maySubmitPrompt: false)
        ledger.recordHumanInput(maySubmitPrompt: true)

        #expect(
            ledger.confirmSubmission(message: nil)
                == .unmatched
        )
        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "programmatic prompt")
                == .programmatic(source: "workspace.agent_submit")
        )
        #expect(
            ledger.confirmSubmission(message: "human prompt")
                == .human
        )
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func duplicateMessagesConfirmInFIFOOrder() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            message: "same prompt",
            source: "first"
        )
        ledger.recordProgrammaticSubmission(
            message: "same prompt",
            source: "second"
        )

        #expect(
            ledger.confirmSubmission(message: "same prompt")
                == .programmatic(source: "first")
        )
        #expect(
            ledger.confirmSubmission(message: "same prompt")
                == .programmatic(source: "second")
        )
    }

    @Test func newAgentScopeDiscardsPreviousAgentRecordsAndInput() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(maySubmitPrompt: false)
        ledger.recordProgrammaticSubmission(
            message: "old prompt",
            source: "workspace.agent_submit"
        )

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(!ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "old prompt")
                == .unmatched
        )
    }

    @Test func unchangedAgentScopePreservesItsHumanDraft() {
        var ledger = TerminalPromptInputLedger()
        ledger.synchronizeAgentScope("agentPIDKey:codex.session")
        ledger.recordHumanInput(maySubmitPrompt: false)

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(ledger.hasUnconfirmedHumanInput)
    }
}
