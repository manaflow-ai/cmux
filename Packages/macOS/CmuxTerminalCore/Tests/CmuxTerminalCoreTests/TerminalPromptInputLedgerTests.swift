import Testing
@testable import CmuxTerminalCore

@Suite struct TerminalPromptInputLedgerTests {
    @Test func unknownInputStaysBusyUntilNextConfirmedHumanSubmission() {
        var ledger = TerminalPromptInputLedger()
        // Unknown input includes cancellation and delete-to-empty paths. They
        // cannot clear ownership without rendered-screen inference.
        ledger.recordHumanInput(.unknown)

        ledger.recordHumanInput(.submissionBoundary)

        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(ledger.confirmSubmission(message: "human prompt") == .human)
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func lateHumanHookDoesNotClearNewerTyping() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)
        ledger.recordHumanInput(.unknown)

        #expect(ledger.confirmSubmission(message: "first prompt") == .human)
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func oneHookCannotConfirmMoreThanOneHumanBoundary() {
        var ledger = TerminalPromptInputLedger()
        ledger.synchronizeAgentScope("agentPIDKey:codex.session")
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)

        #expect(ledger.confirmSubmission(message: "human prompt") == .human)
        #expect(ledger.hasUnconfirmedHumanInput)

        ledger.synchronizeAgentScope("agentPIDKey:next.session")
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func programmaticHookMatchNeverClearsNewerHumanTyping() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            message: "review this",
            source: "workspace.agent_submit"
        )
        ledger.recordHumanInput(.unknown)

        #expect(
            ledger.confirmSubmission(message: "review this")
                == .programmatic(source: "workspace.agent_submit")
        )
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func humanOwnedAppSubmissionRecoversOnlyItsPriorInput() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(.unknown)
        ledger.recordProgrammaticSubmission(
            message: "native composer prompt",
            source: "workspace.prompt_submit",
            confirmsHumanInputSnapshot:
                ledger.humanInputSnapshot
        )
        ledger.recordHumanInput(.unknown)

        #expect(
            ledger.confirmSubmission(message: "native composer prompt")
                == .programmatic(source: "workspace.prompt_submit")
        )
        #expect(ledger.hasUnconfirmedHumanInput)

        ledger.recordHumanInput(.submissionBoundary)
        #expect(ledger.confirmSubmission(message: "newer prompt") == .human)
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func olderAppConfirmationCannotUndoANewerConfirmation() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(.unknown)
        let olderSnapshot = ledger.humanInputSnapshot
        ledger.recordProgrammaticSubmission(
            message: "older",
            source: "workspace.prompt_submit",
            confirmsHumanInputSnapshot: olderSnapshot
        )
        ledger.recordHumanInput(.unknown)
        let newerSnapshot = ledger.humanInputSnapshot
        ledger.recordProgrammaticSubmission(
            message: "newer",
            source: "workspace.prompt_submit",
            confirmsHumanInputSnapshot: newerSnapshot
        )

        #expect(
            ledger.confirmSubmission(message: "newer")
                == .programmatic(source: "workspace.prompt_submit")
        )
        #expect(!ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "older")
                == .programmatic(source: "workspace.prompt_submit")
        )
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func rewrittenHookDegradesSourceAttributionWithoutClearingHuman() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            message: "programmatic prompt",
            source: "workspace.agent_submit"
        )
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)

        #expect(
            ledger.confirmSubmission(message: "rewritten prompt")
                == .unmatched
        )
        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "human prompt") == .human
        )
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func rewrittenAppHookBehindHumanBoundaryCannotConfirmHumanInput() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)
        ledger.recordProgrammaticSubmission(
            message: "programmatic prompt",
            source: "workspace.prompt_submit",
            confirmsHumanInputSnapshot: ledger.humanInputSnapshot
        )

        #expect(
            ledger.confirmSubmission(message: "rewritten app prompt")
                == .unmatched
        )
        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "human prompt") == .human
        )
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func nilProgrammaticHookDoesNotConsumeHumanBoundaryInSameCall() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordProgrammaticSubmission(
            message: "programmatic prompt",
            source: "workspace.agent_submit"
        )
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)

        #expect(
            ledger.confirmSubmission(message: nil)
                == .unmatched
        )
        #expect(ledger.hasUnconfirmedHumanInput)
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

    @Test func initialAgentScopeAdoptsHumanInputButDiscardsAppRecords() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(.unknown)
        ledger.recordProgrammaticSubmission(
            message: "old prompt",
            source: "workspace.agent_submit"
        )

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "old prompt")
                == .unmatched
        )
    }

    @Test func initialAgentScopeRetiresInputThroughLaunchBoundary() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(!ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "pre-binding prompt")
                == .unmatched
        )
    }

    @Test func initialAgentScopePreservesInputAfterLaunchBoundary() {
        var ledger = TerminalPromptInputLedger()
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)
        ledger.recordHumanInput(.unknown)

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "pre-binding prompt")
                == .unmatched
        )
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func changedAgentScopeDiscardsPreviousAgentRecordsAndInput() {
        var ledger = TerminalPromptInputLedger()
        ledger.synchronizeAgentScope("agentPIDKey:first.session")
        ledger.recordHumanInput(.unknown)
        ledger.recordProgrammaticSubmission(
            message: "old prompt",
            source: "workspace.agent_submit"
        )

        ledger.synchronizeAgentScope("agentPIDKey:second.session")

        #expect(!ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "old prompt")
                == .unmatched
        )
    }

    @Test func unchangedAgentScopePreservesItsHumanDraft() {
        var ledger = TerminalPromptInputLedger()
        ledger.synchronizeAgentScope("agentPIDKey:codex.session")
        ledger.recordHumanInput(.unknown)

        ledger.synchronizeAgentScope("agentPIDKey:codex.session")

        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func temporaryScopeUnavailabilityPreservesDraftOnSameProcessRebind() {
        var ledger = TerminalPromptInputLedger()
        let scope = "agentPIDKey:codex.session"
        ledger.synchronizeAgentScope(scope)
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)

        ledger.synchronizeAgentScope(nil)

        #expect(ledger.currentAgentScope == nil)
        #expect(ledger.hasUnconfirmedHumanInput)

        ledger.synchronizeAgentScope(scope)

        #expect(ledger.currentAgentScope == scope)
        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "preserved draft") == .human
        )
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func differentProcessAfterScopeUnavailabilityStartsFreshEpoch() {
        var ledger = TerminalPromptInputLedger()
        ledger.synchronizeAgentScope("agentPIDKey:first.session")
        ledger.recordHumanInput(.unknown)
        ledger.recordProgrammaticSubmission(
            message: "old prompt",
            source: "workspace.agent_submit"
        )

        ledger.synchronizeAgentScope(nil)
        ledger.synchronizeAgentScope("agentPIDKey:second.session")

        #expect(!ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "old prompt") == .unmatched
        )
    }

    @Test func queuedConfirmationFromAPreviousScopeCannotClearCurrentInput() {
        var ledger = TerminalPromptInputLedger()
        ledger.synchronizeAgentScope("agentPIDKey:first.session")
        ledger.recordHumanInput(.unknown)
        let staleSnapshot = ledger.humanInputSnapshot

        ledger.synchronizeAgentScope("agentPIDKey:second.session")
        ledger.recordHumanInput(.unknown)
        ledger.recordProgrammaticSubmission(
            message: "queued prompt",
            source: "workspace.prompt_submit",
            confirmsHumanInputSnapshot: staleSnapshot
        )

        #expect(
            ledger.confirmSubmission(message: "queued prompt")
                == .programmatic(source: "workspace.prompt_submit")
        )
        #expect(ledger.hasUnconfirmedHumanInput)
    }

    @Test func boundaryCapacityRemainsFailClosedAndLaterRecovers() {
        var ledger = TerminalPromptInputLedger()
        for _ in 0..<64 {
            ledger.recordHumanInput(.unknown)
            ledger.recordHumanInput(.submissionBoundary)
        }
        // This boundary is deliberately not retained once the bounded queue
        // is full.
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)

        for index in 0..<64 {
            #expect(
                ledger.confirmSubmission(message: "submitted \(index)")
                    == .human
            )
        }
        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "untracked") == .unmatched
        )

        // Draining older boundaries makes the state recoverable again without
        // changing the agent scope.
        ledger.recordHumanInput(.submissionBoundary)
        #expect(ledger.confirmSubmission(message: "later") == .human)
        #expect(!ledger.hasUnconfirmedHumanInput)
    }

    @Test func programmaticAttributionDegradesWithoutBlockingDelivery() {
        var ledger = TerminalPromptInputLedger()
        for index in 0..<64 {
            ledger.recordProgrammaticSubmission(
                message: "prompt \(index)",
                source: "workspace.agent_submit"
            )
        }
        ledger.recordProgrammaticSubmission(
            message: "prompt 64",
            source: "workspace.agent_submit"
        )
        ledger.recordHumanInput(.unknown)
        ledger.recordHumanInput(.submissionBoundary)

        #expect(
            ledger.confirmSubmission(message: "prompt 0") == .unmatched
        )
        #expect(ledger.hasUnconfirmedHumanInput)
        #expect(
            ledger.confirmSubmission(message: "prompt 64")
                == .programmatic(source: "workspace.agent_submit")
        )
        #expect(ledger.hasUnconfirmedHumanInput)
        // A rewritten hook consumes the next sequence-only programmatic
        // boundary before the human boundary can be confirmed.
        #expect(
            ledger.confirmSubmission(message: "rewritten prompt")
                == .unmatched
        )
        // Remaining exact programmatic records still match by message without
        // consuming the later human boundary.
        #expect(
            ledger.confirmSubmission(message: "prompt 63")
                == .programmatic(source: "workspace.agent_submit")
        )
        // Starting a new process epoch deterministically retires any hook
        // uncertainty without blocking future programmatic submissions.
        ledger.synchronizeAgentScope("agentPIDKey:next.session")
        ledger.recordProgrammaticSubmission(
            message: "next response",
            source: "workspace.agent_submit"
        )
        #expect(
            ledger.confirmSubmission(message: "next response")
                == .programmatic(source: "workspace.agent_submit")
        )
    }
}
