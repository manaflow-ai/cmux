#if os(iOS)
import CMUXAuthCore
import Testing
@testable import CmuxMobileShellUI

/// Per-environment sign-out routing (the root view's choke point), keyed on
/// the SELECTION: only EXPLICIT staging warns before an interactive sign-out
/// and chains the return to the build's lane; a staging-LANE dev rig keeps
/// today's plain sign-out, production never warns and never chains, and the
/// post-account-deletion direct path skips the warning but still chains.
@Suite
struct MobileSignOutInterceptionTests {
    @Test
    func interactiveSignOutOnTheProductionLanePerformsDirectlyWithoutChaining() {
        #expect(MobileSignOutInterception.route(
            for: .interactive,
            selection: .lane(resolves: .production)
        ) == .perform(returnsToLane: false))
    }

    @Test
    func interactiveSignOutOnExplicitProductionStaysPlain() {
        // Explicit production is a wholesale choice, but sign-out there has
        // nothing to warn about and nothing to chain.
        #expect(MobileSignOutInterception.route(
            for: .interactive,
            selection: .explicit(.production)
        ) == .perform(returnsToLane: false))
    }

    @Test
    func interactiveSignOutOnExplicitStagingWarnsFirst() {
        #expect(MobileSignOutInterception.route(
            for: .interactive,
            selection: .explicit(.staging)
        ) == .confirmStagingFirst)
    }

    @Test
    func stagingLaneNeverInterceptsOrChains() {
        // A staging-LANE build's home IS staging: dev-rig sign-outs must
        // stay plain sign-outs, with no warning and no chained switch — the
        // interception keys on the SELECTION, not the resolved environment.
        #expect(MobileSignOutInterception.route(
            for: .interactive,
            selection: .lane(resolves: .staging)
        ) == .perform(returnsToLane: false))
        #expect(MobileSignOutInterception.route(
            for: .direct,
            selection: .lane(resolves: .staging)
        ) == .perform(returnsToLane: false))
    }

    @Test
    func confirmedStagingSignOutChainsTheReturnToTheLane() {
        // The confirmed warning runs the REAL sign-out under the staging
        // defaults, then chains the switch back to the build's LANE —
        // restoring its parked session (production on every unpinned build).
        #expect(MobileSignOutInterception.confirmedStagingRoute
            == .perform(returnsToLane: true))
    }

    @Test
    func deletedAccountSignOutOnExplicitStagingSkipsTheWarningButStillChains() {
        // The account is gone; warning about ending its staging session
        // would be meaningless, but the device must still return to its
        // lane.
        #expect(MobileSignOutInterception.route(
            for: .direct,
            selection: .explicit(.staging)
        ) == .perform(returnsToLane: true))
    }

    @Test
    func deletedAccountSignOutOnProductionStaysPlain() {
        #expect(MobileSignOutInterception.route(
            for: .direct,
            selection: .lane(resolves: .production)
        ) == .perform(returnsToLane: false))
        #expect(MobileSignOutInterception.route(
            for: .direct,
            selection: .explicit(.production)
        ) == .perform(returnsToLane: false))
    }
}
#endif
