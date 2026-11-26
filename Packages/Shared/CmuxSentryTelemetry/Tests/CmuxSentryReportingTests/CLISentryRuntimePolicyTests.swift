import Sentry
import Testing

@testable import CmuxSentryReporting

@Suite struct CLISentryRuntimePolicyTests {
    @Test func shortLivedCLIProfileDoesNotWaitForSentryShutdown() {
        let options = Options()

        CLISentryRuntimePolicy().configure(options)

        #expect(options.shutdownTimeInterval == 0)
        #expect(options.enableAppHangTracking == false)
        #expect(options.enableWatchdogTerminationTracking == false)
        #expect(options.enableAutoSessionTracking == false)
        #expect(options.enableLogs == false)
        #expect(options.enableMetricKit == false)
    }
}
