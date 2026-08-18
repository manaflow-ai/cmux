import Foundation
import Testing

@testable import CmuxMobileShell

// Regression coverage for the while-connected secondary dial churn seen in
// field diagnostics: an unreachable secondary Mac was redialed on the fresh
// 2 s control-pool ladder every foreground session, because backgrounding
// fully reset the shared retry state. Backgrounding says nothing about the
// Mac becoming reachable, so the grown delay must survive; only account/team
// boundaries forget it.
@MainActor
@Suite
struct SecondaryAggregationRetryLadderTests {
    @Test
    func backgroundSuspensionPreservesGrownRetryDelay() {
        let composite = MobileShellComposite(workspaces: [])
        _ = composite.secondaryAggregationRetryState.schedule()
        composite.secondaryAggregationRetryState.fire()

        composite.suspendSecondaryConnectionEstablishmentForBackground()

        #expect(
            composite.secondaryAggregationRetryState.schedule() == .seconds(4)
        )
    }

    @Test
    func accountBoundaryStillResetsRetryDelay() {
        let composite = MobileShellComposite(workspaces: [])
        _ = composite.secondaryAggregationRetryState.schedule()
        composite.secondaryAggregationRetryState.fire()

        composite.cancelSecondaryAggregationRetry()

        #expect(
            composite.secondaryAggregationRetryState.schedule() == .seconds(2)
        )
    }
}
