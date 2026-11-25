@testable import CmuxNextControl
import Testing

/// `CMUX_TRACE_FILE` (the daemon's Chrome trace of each user action, acpmux perf_trace.rs, cmux#55505) set on
/// the app's own launch survives the launch strip, so the acpmux daemon it starts writes the trace
/// (scripts/measure/action-trace.sh); one another cmux's terminal passed on is that cmux's, and goes.
@Suite struct LaunchIdentityTraceFileTests {
    @Test func theTraceFileSurvivesTheStripUnlessAnotherCmuxSetIt() {
        let own = [LaunchIdentity.traceFileKey: "/tmp/cmux-trace.json"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: own, bundledEnvironment: [:]).isEmpty)
        let foreign = [LaunchIdentity.traceFileKey: "/tmp/cmux-trace.json", "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"]
        #expect(Set(LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:])).contains(LaunchIdentity.traceFileKey))
    }
}
