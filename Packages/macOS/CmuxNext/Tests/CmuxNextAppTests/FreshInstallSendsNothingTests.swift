@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextHangReports
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// A fresh install (no preference, no setting) starts no crash reporter or analytics and sends
/// nothing until the person turns it on (Leo, 2026-11-24: "whatever we do, we need to make sure
/// it's opt out by defautl i assume?"). Only the person's own write of
/// `app.sendAnonymousTelemetry` turns it on.
@MainActor @Suite(.serialized) struct FreshInstallSendsNothingTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "cn-fresh-install-\(UUID().uuidString)"
        return (UserDefaults(testSuiteName: suite)!, suite)
    }

    /// This launch's reporter for a Release, NIGHTLY or RC bundle over `defaults`, with no managed
    /// policy and no test-process variables (so only the person's choice decides).
    private func reporter(bundleID: String, defaults: UserDefaults) -> CrashReporter {
        CrashReporter.forThisLaunch(bundleID: bundleID, info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"],
                                    defaults: defaults, managed: FixedManagedPreferenceReader(ManagedPreferences()),
                                    environment: [:])
    }

    @Test func aFreshInstallStartsNoCrashReporterOnAnyChannel() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!CrashReportingPolicy.telemetryOptIn(in: defaults), "unset means off")
        for bundleID in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"] {
            let reporter = reporter(bundleID: bundleID, defaults: defaults)
            #expect(!reporter.policy.shouldStart, "\(bundleID) must not start Sentry on a fresh install")
            #expect(!reporter.start(), "\(bundleID) started Sentry on a fresh install")
            #expect(!reporter.isStarted)
        }
        // Nothing reaches Sentry while it is not started.
        let reporter = reporter(bundleID: "com.cmuxterm.app", defaults: defaults)
        reporter.recordFailure("fresh", message: "install")
        reporter.addBreadcrumb(category: "fresh", message: "install")
        #expect(!reporter.isStarted)
    }

    @Test func aFreshInstallNeverInvitesHangReports() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(HangReportsController.decision(defaults: defaults, settingOn: false) == .off)
    }

    @Test func turningItOnIsThePersonsChoice() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CrashReportingPolicy.telemetryKey)
        #expect(CrashReportingPolicy.telemetryOptIn(in: defaults))
        #expect(reporter(bundleID: "com.cmuxterm.app", defaults: defaults).policy.shouldStart)
        defaults.set(false, forKey: CrashReportingPolicy.telemetryKey)
        #expect(!reporter(bundleID: "com.cmuxterm.app", defaults: defaults).policy.shouldStart)
    }

    @Test func thePersonsWriteOfTheSettingReachesThePreference() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()
        var earlierHookRan = false
        settings.userWillWrite = { _, _ in earlierHookRan = true; return nil }
        AnonymousTelemetryConsent.install(on: settings, defaults: defaults)

        // The schema default is off.
        let descriptor = try #require(SettingsSchema.descriptor(for: AnonymousTelemetryConsent.configPath))
        #expect(descriptor.defaultValue == .bool(false))

        // A write by anyone but the person turns nothing on.
        _ = try? await settings.setSetting(at: AnonymousTelemetryConsent.configPath, to: .bool(true), by: .caller("cli"))
        #expect(defaults.object(forKey: CrashReportingPolicy.telemetryKey) == nil)

        try await settings.setSetting(at: AnonymousTelemetryConsent.configPath, to: .bool(true), by: .user)
        #expect(CrashReportingPolicy.telemetryOptIn(in: defaults))
        #expect(earlierHookRan, "the hang reports hook still runs")
        try await settings.setSetting(at: AnonymousTelemetryConsent.configPath, to: .bool(false), by: .user)
        #expect(!CrashReportingPolicy.telemetryOptIn(in: defaults))
    }

    @Test func aFailedWriteRestoresTheEarlierPreference() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let undo = AnonymousTelemetryConsent.recordUserWrite(defaults: defaults, path: AnonymousTelemetryConsent.configPath, value: .bool(true))
        #expect(CrashReportingPolicy.telemetryOptIn(in: defaults))
        undo?()
        #expect(defaults.object(forKey: CrashReportingPolicy.telemetryKey) == nil)
        #expect(AnonymousTelemetryConsent.recordUserWrite(defaults: defaults, path: ["terminal", "fontSize"], value: .number(15)) == nil)
    }
}
