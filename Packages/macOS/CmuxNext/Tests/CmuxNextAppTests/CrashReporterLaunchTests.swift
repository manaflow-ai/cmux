@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextSettings
import Foundation
import Testing

/// cx-urd.58: the app reads the consent inputs the main app reads: the
/// user's `sendAnonymousTelemetry` choice and a forced `DisableTelemetry`.
@Suite struct CrashReporterLaunchTests {
    nonisolated struct Managed: ManagedPreferenceReader {
        var forced: [String: CmuxNextSettings.JSONValue] = [:]
        func read() -> ManagedPreferences { ManagedPreferences(forced: forced) }
    }

    /// Test builds are Debug compiles (DEV): they report only with the opt-in.
    private func reporter(optIn: Bool?, forced: [String: CmuxNextSettings.JSONValue] = [:],
                          environment: [String: String] = [CrashReportingPolicy.devOptInKey: "1"]) throws -> CrashReporter {
        let name = "crash-launch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        if let optIn { defaults.set(optIn, forKey: CrashReportingPolicy.telemetryKey) }
        return CrashReporter.forThisLaunch(
            bundleID: "com.cmuxterm.app.nightly.nxsntr",
            info: ["CFBundleShortVersionString": "1.0.0-nightly.42", "CFBundleVersion": "42"],
            defaults: defaults, managed: Managed(forced: forced), environment: environment)
    }

    @Test func consentAndLabelsComeFromTheLaunch() throws {
        let on = try reporter(optIn: nil)
        #expect(on.policy.shouldStart, "on until the user turns it off")
        #expect(on.policy.release == "cmux-next@1.0.0-nightly.42+42")
        #expect(on.policy.devTag == "nxsntr")
        #expect(try !reporter(optIn: false).policy.shouldStart)
        #expect(try !reporter(optIn: true, forced: ["DisableTelemetry": .bool(true)]).policy.shouldStart)
        #expect(try reporter(optIn: true, forced: ["DisableTelemetry": .bool(false)]).policy.shouldStart)
        #expect(try !reporter(optIn: nil, environment: [:]).policy.shouldStart, "DEV is off without the opt-in")
    }

    @Test func disableTelemetryIsAPublishedPolicyKeyAlsoReadFromTheShippedAppsDomain() {
        #expect(ManagedPreferences.policyKeys.contains { $0.name == CrashReportingPolicy.disableTelemetryPolicyKey })
        #expect(ManagedPreferences.legacyKeys.contains(CrashReportingPolicy.disableTelemetryPolicyKey))
        #expect(CFManagedPreferenceReader.publishedKeys.contains(CrashReportingPolicy.disableTelemetryPolicyKey))
    }
}
