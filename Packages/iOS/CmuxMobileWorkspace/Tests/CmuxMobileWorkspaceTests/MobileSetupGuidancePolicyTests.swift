import Testing

@testable import CmuxMobileWorkspace

/// Truth-table tests for ``MobileSetupGuidancePolicy``, the pure classifier that
/// names which pre-pairing setup gate the user is stuck behind.
@Suite struct MobileSetupGuidancePolicyTests {
    /// Fresh install, no session: nothing can be attempted until sign-in.
    @Test func notSignedInWhenNoSession() {
        #expect(
            MobileSetupGuidancePolicy.state(
                isSignedIn: false,
                hasKnownPairedMac: false,
                hasAccountMismatch: false
            ) == .notSignedIn
        )
    }

    /// Signed in but never paired and nothing on record: guide to install/run the
    /// Mac app and pair.
    @Test func neverPairedWhenSignedInWithNoMac() {
        #expect(
            MobileSetupGuidancePolicy.state(
                isSignedIn: true,
                hasKnownPairedMac: false,
                hasAccountMismatch: false
            ) == .signedInNeverPaired
        )
    }

    /// Signed in with a known Mac that is currently unreachable: guide to wake the
    /// Mac and reconnect.
    @Test func unreachableWhenSignedInWithKnownMac() {
        #expect(
            MobileSetupGuidancePolicy.state(
                isSignedIn: true,
                hasKnownPairedMac: true,
                hasAccountMismatch: false
            ) == .macUnreachable
        )
    }

    /// An account mismatch is the most specific, actionable failure, so it wins
    /// even when signed in with a known Mac.
    @Test func accountMismatchWinsOverEverythingElse() {
        #expect(
            MobileSetupGuidancePolicy.state(
                isSignedIn: true,
                hasKnownPairedMac: true,
                hasAccountMismatch: true
            ) == .accountMismatch
        )
        #expect(
            MobileSetupGuidancePolicy.state(
                isSignedIn: false,
                hasKnownPairedMac: false,
                hasAccountMismatch: true
            ) == .accountMismatch
        )
    }

    /// Every state is reachable through the classifier, so the help screen never
    /// has a gate it cannot land on.
    @Test func everyStateIsReachable() {
        var seen = Set<MobileSetupGuidanceState>()
        for isSignedIn in [false, true] {
            for hasKnownPairedMac in [false, true] {
                for hasAccountMismatch in [false, true] {
                    seen.insert(
                        MobileSetupGuidancePolicy.state(
                            isSignedIn: isSignedIn,
                            hasKnownPairedMac: hasKnownPairedMac,
                            hasAccountMismatch: hasAccountMismatch
                        )
                    )
                }
            }
        }
        #expect(seen == Set(MobileSetupGuidanceState.allCases))
    }
}
