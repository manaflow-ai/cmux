import CmuxNextCompat
import Testing
@testable import CmuxNextDaemon

/// p10-stability-201: MallocProbGuard reaches the daemon on a sampled share of Nightly launches only, never
/// on Release or RC, and on other builds only when the app itself was started with it (vm.sh --diag probguard).
struct DaemonLaunchEnvironmentTests {
    private let probGuard = ["MallocProbGuard": "1"]

    @Test func aSampledNightlyLaunchGetsProbGuard() {
        #expect(DaemonLaunchEnvironment(kind: .nightly, processEnvironment: [:], roll: 0).environment == probGuard)
        #expect(DaemonLaunchEnvironment(kind: .nightly, processEnvironment: [:], roll: 0.0499).environment == probGuard)
    }

    @Test func anUnsampledNightlyLaunchGetsNothing() {
        #expect(DaemonLaunchEnvironment(kind: .nightly, processEnvironment: [:], roll: 0.05).environment.isEmpty)
        #expect(DaemonLaunchEnvironment(kind: .nightly, processEnvironment: [:], roll: 0.99).environment.isEmpty)
    }

    @Test func releaseAndRCNeverGetProbGuard() {
        for kind in [BuildIdentity.Kind.release, .rc] {
            #expect(DaemonLaunchEnvironment(kind: kind, processEnvironment: [:], roll: 0).environment.isEmpty)
            #expect(DaemonLaunchEnvironment(kind: kind, processEnvironment: probGuard, roll: 0).environment.isEmpty)
        }
    }

    @Test func otherBuildsForwardOnlyTheAppsOwnRequest() {
        for kind in [BuildIdentity.Kind.dev, .staging, .unbundled] {
            #expect(DaemonLaunchEnvironment(kind: kind, processEnvironment: [:], roll: 0).environment.isEmpty)
            #expect(DaemonLaunchEnvironment(kind: kind, processEnvironment: probGuard, roll: 0.99).environment == probGuard)
            #expect(DaemonLaunchEnvironment(kind: kind, processEnvironment: ["MallocProbGuard": "0"], roll: 0)
                .environment.isEmpty)
        }
        #expect(DaemonLaunchEnvironment(kind: .nightly, processEnvironment: probGuard, roll: 0.99).environment == probGuard)
    }

    /// The sample rate is the documented 5 %: a change to it is a reviewed decision, not a drift.
    @Test func theNightlyRateIsFivePercent() {
        #expect(DaemonLaunchEnvironment.nightlySampleRate == 0.05)
    }
}
