import Testing

@testable import CmuxTerminal

@MainActor
@Suite struct MobileViewportMetricsReapplyTests {
    @Test func activeFitCoalescesMetricsCallbacksIntoOneFollowUp() {
        let state = MobileViewportMetricsReapplyState()
        var reapplyCount = 0

        state.cellMetricsDidChange { reapplyCount += 1 }
        #expect(reapplyCount == 1)

        #expect(state.beginViewportLimitApplication())
        state.cellMetricsDidChange { reapplyCount += 1 }
        state.cellMetricsDidChange { reapplyCount += 1 }
        #expect(reapplyCount == 1)

        state.endViewportLimitApplication { reapplyCount += 1 }
        #expect(reapplyCount == 2)
    }

    @Test func followUpMetricsCallbacksDrainToABoundedFixedPoint() {
        let state = MobileViewportMetricsReapplyState()
        var followUpPassCount = 0

        #expect(state.beginViewportLimitApplication())
        state.cellMetricsDidChange {
            Issue.record("active metrics callback must be deferred")
        }
        state.endViewportLimitApplication {
            followUpPassCount += 1
            #expect(state.beginViewportLimitApplication())
            state.cellMetricsDidChange {
                Issue.record("nested metrics callback must stay with the drain owner")
            }
            state.endViewportLimitApplication {
                Issue.record("nested completion must not create a second drain owner")
            }
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

        let queuedCallbackGeneration = try #require(
            state.activeTransactionGeneration
        )
        var followUpPassCount = 0
        for _ in 0..<(MobileViewportMetricsReapplyState.maxMetricsFollowUpPasses + 3) {
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
