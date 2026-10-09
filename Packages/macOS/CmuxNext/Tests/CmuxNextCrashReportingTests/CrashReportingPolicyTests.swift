@testable import CmuxNextCrashReporting
import Foundation
import Testing

/// cx-urd.58: cmux-next sends crash reports under the main app's consent
/// rule, labeled so they never mix with the main app's reports.
@Suite struct CrashReportingPolicyTests {
    private func policy(_ bundleID: String?, debug: Bool = false, optIn: Bool = true, managedOff: Bool = false,
                        env: [String: String] = [:]) -> CrashReportingPolicy {
        CrashReportingPolicy(bundleID: bundleID, shortVersion: "1.0.0-nightly.1834001", build: "1834001",
                             isDebugBuild: debug, telemetryOptIn: optIn, managedDisablesTelemetry: managedOff,
                             processEnvironment: env)
    }

    @Test func everyChannelHasItsOwnNextEnvironment() {
        #expect(policy("com.cmuxterm.app.nightly").environment == "nightly-next")
        #expect(policy("com.cmuxterm.app.nightly.nxdog66-v1").environment == "nightly-next")
        #expect(policy("com.cmuxterm.app.rc").environment == "rc-next")
        #expect(policy("com.cmuxterm.app").environment == "release-next")
        #expect(policy("com.cmuxterm.app.debug.hmdm2", debug: true).environment == "dev")
        #expect(policy("com.cmuxterm.app.debug").environment == "dev")
        #expect(policy("com.cmuxterm.app.staging").environment == "dev")
        // A Debug compile is DEV whatever its bundle says.
        #expect(policy("com.cmuxterm.app.nightly", debug: true).environment == "dev")
    }

    @Test func releaseIsTheCmuxNextVersionAndTagsAreKept() {
        let nightly = policy("com.cmuxterm.app.nightly.nxdog66-v1")
        #expect(nightly.release == "cmux-next@1.0.0-nightly.1834001+1834001")
        #expect(nightly.dist == "1834001")
        #expect(nightly.devTag == "nxdog66-v1")
        #expect(policy("com.cmuxterm.app.debug.hmdm2", debug: true).devTag == "hmdm2")
        #expect(policy("com.cmuxterm.app").devTag == nil)
    }

    @Test func consentFollowsTheMainAppRule() {
        #expect(policy("com.cmuxterm.app.nightly").shouldStart)
        #expect(!policy("com.cmuxterm.app.nightly", optIn: false).shouldStart, "the user turned telemetry off")
        #expect(!policy("com.cmuxterm.app.nightly", managedOff: true).shouldStart, "DisableTelemetry wins")
        #expect(!policy("com.example.fork").shouldStart, "a fork keeps the source, never our DSN")
        #expect(!policy(nil, debug: true).shouldStart)
        #expect(!policy("com.cmuxterm.app.debug.t", debug: true, env: ["XCTestConfigurationFilePath": "/x"]).shouldStart)
        #expect(!policy("com.cmuxterm.app.debug.t", debug: true, env: ["CMUX_UI_TEST_MODE": "1"]).shouldStart)
        #expect(policy("com.cmuxterm.app.debug.t", debug: true,
                       env: ["CMUX_TEST_PROCESS": "1", "CMUX_TEST_SENTRY_ENABLED": "1"]).shouldStart)
    }

    @Test func theTelemetryChoiceIsOnUntilTheUserTurnsItOff() throws {
        let name = "crash-policy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CrashReportingPolicy.telemetryOptIn(in: defaults))
        defaults.set(false, forKey: CrashReportingPolicy.telemetryKey)
        #expect(!CrashReportingPolicy.telemetryOptIn(in: defaults))
        defaults.set(true, forKey: CrashReportingPolicy.telemetryKey)
        #expect(CrashReportingPolicy.telemetryOptIn(in: defaults))
    }
}
