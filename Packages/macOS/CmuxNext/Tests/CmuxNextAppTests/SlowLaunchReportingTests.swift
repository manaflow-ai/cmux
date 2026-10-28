@testable import CmuxNextApp
import Foundation
import Testing

/// Only a build that may send hang reports, on a Mac with the consent record, makes the slow-launch ring
/// (p08-startup-111); every other launch allocates nothing.
@MainActor @Suite struct SlowLaunchReportingTests {
    private static let nightly = "com.cmuxterm.app.nightly"

    private static func defaults(consented: Bool) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "test.slow-launch.\(UUID().uuidString)"))
        if consented { defaults.set(Date(), forKey: HangReportsController.consentKey) }
        return defaults
    }

    @Test func onlyASendingBuildWithTheConsentRecordMakesTheRing() throws {
        let yes = try Self.defaults(consented: true), no = try Self.defaults(consented: false)
        #expect(HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: false, defaults: yes, environment: [:]))
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: false, defaults: no, environment: [:]))
        // Release never sends; DEV only with the opt-in; a test process never.
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: "com.cmuxterm.app", isDebugBuild: false, defaults: yes, environment: [:]))
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: true, defaults: yes, environment: [:]))
        #expect(HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: true, defaults: yes,
                                                       environment: [HangReportsController.devOptInKey: "1"]))
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: false, defaults: yes,
                                                        environment: ["CMUX_TEST_PROCESS": "1"]))
    }
}
