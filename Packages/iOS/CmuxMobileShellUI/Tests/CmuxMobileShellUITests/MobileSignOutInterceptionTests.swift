#if os(iOS)
import CMUXAuthCore
import Testing
@testable import CmuxMobileShellUI

/// Per-environment sign-out routing (the root view's choke point): staging
/// warns before an interactive sign-out and chains the return to Production,
/// production never warns and never chains, and the post-account-deletion
/// direct path skips the warning but still chains.
@Suite
struct MobileSignOutInterceptionTests {
    @Test
    func interactiveSignOutOnProductionPerformsDirectlyWithoutChaining() {
        #expect(MobileSignOutInterception.route(
            for: .interactive,
            active: .production
        ) == .perform(returnsToProduction: false))
    }

    @Test
    func interactiveSignOutOnStagingWarnsFirst() {
        #expect(MobileSignOutInterception.route(
            for: .interactive,
            active: .staging
        ) == .confirmStagingFirst)
    }

    @Test
    func confirmedStagingSignOutChainsTheReturnToProduction() {
        // The confirmed warning runs the REAL sign-out under the staging
        // defaults, then chains the switch back — restoring the parked
        // production session.
        #expect(MobileSignOutInterception.confirmedStagingRoute
            == .perform(returnsToProduction: true))
    }

    @Test
    func deletedAccountSignOutOnStagingSkipsTheWarningButStillChains() {
        // The account is gone; warning about ending its staging session
        // would be meaningless, but the device must still return to
        // Production.
        #expect(MobileSignOutInterception.route(
            for: .direct,
            active: .staging
        ) == .perform(returnsToProduction: true))
    }

    @Test
    func deletedAccountSignOutOnProductionStaysPlain() {
        #expect(MobileSignOutInterception.route(
            for: .direct,
            active: .production
        ) == .perform(returnsToProduction: false))
    }
}
#endif
