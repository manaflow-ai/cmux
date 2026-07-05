import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobileScrollPrefetchPolicyTests {
    @Test func standardPolicyMatchesLegacyBudgets() {
        let policy = MobileScrollPrefetchPolicy()
        #expect(policy.replayScrollbackLineBudget == 240)
        #expect(policy.prefetchScrollbackLineBudget == 600)
    }

    @Test func negativeOrZeroRequestYieldsZero() {
        let policy = MobileScrollPrefetchPolicy()
        #expect(policy.rowsToPrefetch(requestedRows: 0) == 0)
        #expect(policy.rowsToPrefetch(requestedRows: -1) == 0)
        #expect(policy.rowsToPrefetch(requestedRows: -10_000) == 0)
    }

    @Test func positiveRequestIsCappedAtPrefetchBudget() {
        let policy = MobileScrollPrefetchPolicy()
        #expect(policy.rowsToPrefetch(requestedRows: 1) == 1)
        #expect(policy.rowsToPrefetch(requestedRows: 599) == 599)
        #expect(policy.rowsToPrefetch(requestedRows: 600) == 600)
        #expect(policy.rowsToPrefetch(requestedRows: 601) == 600)
        #expect(policy.rowsToPrefetch(requestedRows: Int.max) == 600)
    }

    @Test func clampHonorsCustomBudget() {
        let policy = MobileScrollPrefetchPolicy(
            replayScrollbackLineBudget: 10,
            prefetchScrollbackLineBudget: 50
        )
        #expect(policy.rowsToPrefetch(requestedRows: 75) == 50)
        #expect(policy.rowsToPrefetch(requestedRows: 25) == 25)
    }
}
