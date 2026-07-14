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
}
