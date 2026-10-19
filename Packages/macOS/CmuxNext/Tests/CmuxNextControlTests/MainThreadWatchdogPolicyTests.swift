@testable import CmuxNextControl
import Testing

struct MainThreadWatchdogPolicyTests {
    @Test func noActivateDiagnosticLaunchKeepsWatchdogEvidenceAlive() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: true, noActivate: true) == nil)
    }

    @Test func interactiveDebugLaunchKeepsHangAssertion() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: true, noActivate: false) == .seconds(10))
    }

    @Test func releaseLaunchNeverAsserts() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: false, noActivate: false) == nil)
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: false, noActivate: true) == nil)
    }
}
