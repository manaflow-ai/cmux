import Testing

@testable import CmuxTerminal

@MainActor
@Suite struct MobileViewportMetricsReapplyTests {
    @Test func activeFitCoalescesDuplicateMetricsCallbacksIntoOneFollowUp() throws {
        let state = MobileViewportMetricsReapplyState()
        let initial = try #require(state.beginViewportLimitApplication(resuming: nil))
        state.endViewportLimitApplication(
            generation: initial,
            expectsCellMetricsCallback: true
        )

        let followUp = try #require(
            state.beginViewportLimitApplication(resuming: initial)
        )
        #expect(state.beginViewportLimitApplication(resuming: initial) == nil)
        state.endViewportLimitApplication(
            generation: followUp,
            expectsCellMetricsCallback: false
        )
        #expect(state.activeTransactionGeneration == nil)
    }

    @Test func followUpMetricsCallbacksDrainToABoundedFixedPoint() {
        let state = MobileViewportMetricsReapplyState()
        var followUpPassCount = 0

        guard let initial = state.beginViewportLimitApplication(resuming: nil) else {
            Issue.record("initial application must start")
            return
        }
        state.endViewportLimitApplication(
            generation: initial,
            expectsCellMetricsCallback: true
        )
        while let callbackGeneration = state.activeTransactionGeneration,
              let followUp = state.beginViewportLimitApplication(
                resuming: callbackGeneration
            ) {
            followUpPassCount += 1
            state.endViewportLimitApplication(
                generation: followUp,
                expectsCellMetricsCallback: true
            )
        }

        #expect(followUpPassCount == MobileViewportMetricsReapplyState.maxMetricsFollowUpPasses)
    }

    @Test func queuedMetricsCallbacksShareOneTransactionBudget() throws {
        let state = MobileViewportMetricsReapplyState()
        let generation = try #require(
            state.beginViewportLimitApplication(resuming: nil)
        )
        state.endViewportLimitApplication(
            generation: generation,
            expectsCellMetricsCallback: true
        )

        var followUpPassCount = 0
        for _ in 0..<(MobileViewportMetricsReapplyState.maxMetricsFollowUpPasses + 3) {
            guard let queuedCallbackGeneration = state.activeTransactionGeneration else {
                continue
            }
            guard let followUpGeneration = state.beginViewportLimitApplication(
                resuming: queuedCallbackGeneration
            ) else { continue }
            followUpPassCount += 1
            state.endViewportLimitApplication(
                generation: followUpGeneration,
                expectsCellMetricsCallback: true
            )
        }

        #expect(followUpPassCount == MobileViewportMetricsReapplyState.maxMetricsFollowUpPasses)
        #expect(state.activeTransactionGeneration == nil)
    }

    @Test func staleQueuedMetricsCallbackCannotResumeNewerTransaction() throws {
        let state = MobileViewportMetricsReapplyState()
        let first = try #require(state.beginViewportLimitApplication(resuming: nil))
        state.endViewportLimitApplication(
            generation: first,
            expectsCellMetricsCallback: true
        )

        let second = try #require(state.beginViewportLimitApplication(resuming: nil))
        state.endViewportLimitApplication(
            generation: second,
            expectsCellMetricsCallback: true
        )

        #expect(state.beginViewportLimitApplication(resuming: first) == nil)
        #expect(state.activeTransactionGeneration == second)
    }
}
