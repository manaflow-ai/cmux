import AppKit
@testable import CmuxNextApp
import CmuxNextTestSupport
import Foundation
import Testing

/// Capture builds skip the first-run onboarding pages with `CMUX_NEXT_SKIP_ONBOARDING=1` or
/// `--skip-onboarding`, so a fresh tagged app opens on its real windows. Unlike the showcase
/// profile, nothing else changes: accounts, agents and notifications stay real.
@MainActor @Suite(.serialized)
struct SkipOnboardingLaunchTests {
    @Test(arguments: [
        (["CMUX_NEXT_SKIP_ONBOARDING": "1"], [String]()),
        ([String: String](), ["cmux", "--skip-onboarding"]),
    ])
    func theFlagSkipsOnboardingOnly(environment: [String: String], arguments: [String]) {
        let launch = AppEnvironment.current(environment, arguments: arguments)
        #expect(launch.skipsOnboarding)
        #expect(!launch.showcase)
    }

    @Test func aPlainLaunchKeepsOnboarding() {
        #expect(!AppEnvironment.current([:], arguments: ["cmux"]).skipsOnboarding)
    }

    @Test func theFirstRunHistoryPageNeverRunsUnderTheFlag() throws {
        _ = NSApplication.shared
        let key = "home.firstRun.historyImportShown"
        let suite = "SkipOnboardingLaunchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let plain = AppServices(environment: AppEnvironment.current([:], arguments: ["cmux"]))
        plain.onboarding.showHistoryAtFirstRun(isFirstRun: false, defaults: defaults)
        #expect(defaults.bool(forKey: key))

        defaults.removeObject(forKey: key)
        let skipping = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SKIP_ONBOARDING": "1"], arguments: ["cmux"]))
        skipping.onboarding.showHistoryAtFirstRun(isFirstRun: true, defaults: defaults)
        #expect(!defaults.bool(forKey: key))
    }
}
