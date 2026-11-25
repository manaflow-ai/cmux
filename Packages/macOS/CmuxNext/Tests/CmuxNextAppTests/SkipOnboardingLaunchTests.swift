import AppKit
@testable import CmuxNextApp
import CmuxNextOnboarding
import CmuxNextTestSupport
import Foundation
import Testing

/// Onboarding is off for now (Lawrence 2026-11-09: "get rid of onboarding completely for now"): a plain launch,
/// fresh profile or not, shows no first-run window, no Set Up cmux card and no Bring your history page. The code
/// stays: `CMUX_NEXT_ONBOARDING=1` or `--onboarding` turns it back on. Capture builds still skip it with
/// `CMUX_NEXT_SKIP_ONBOARDING=1` or `--skip-onboarding`, which wins over the opt-in. Unlike the showcase
/// profile, nothing else changes: accounts, agents and notifications stay real.
@MainActor @Suite(.serialized)
struct SkipOnboardingLaunchTests {
    @Test(arguments: [
        (["CMUX_NEXT_SKIP_ONBOARDING": "1"], [String]()),
        ([String: String](), ["cmux", "--skip-onboarding"]),
        (["CMUX_NEXT_ONBOARDING": "1", "CMUX_NEXT_SKIP_ONBOARDING": "1"], [String]()),
    ])
    func theFlagSkipsOnboardingOnly(environment: [String: String], arguments: [String]) {
        let launch = AppEnvironment.current(environment, arguments: arguments)
        #expect(launch.skipsOnboarding)
        #expect(!launch.showcase)
    }

    @Test func aPlainLaunchShowsNoOnboarding() {
        #expect(AppEnvironment.current([:], arguments: ["cmux"]).skipsOnboarding)
    }

    @Test(arguments: [
        (["CMUX_NEXT_ONBOARDING": "1"], ["cmux"]),
        ([String: String](), ["cmux", "--onboarding"]),
    ])
    func theOptInBringsOnboardingBack(environment: [String: String], arguments: [String]) {
        #expect(!AppEnvironment.current(environment, arguments: arguments).skipsOnboarding)
    }

    /// A fresh profile on a plain launch: the first run starts no Set Up cmux card, and a card left pending by an
    /// earlier build no longer shows.
    @Test func aFreshProfileGetsNoSetupCard() throws {
        let suite = "SkipOnboardingLaunchTests.card.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plain = AppEnvironment.current([:], arguments: ["cmux"])

        let fresh = FirstRunSetup(defaults: defaults, skipsOnboarding: plain.skipsOnboarding)
        #expect(!fresh.begin(isFirstRun: true, replacedKeys: ["cli.install.offeredAtLaunch"]))
        #expect(!fresh.shows)

        defaults.set("pending", forKey: FirstRunSetup.stateKey)
        #expect(!FirstRunSetup(defaults: defaults, skipsOnboarding: plain.skipsOnboarding).shows)
    }

    @Test func theFirstRunHistoryPageNeverRunsUnderTheFlag() throws {
        _ = NSApplication.shared
        let key = "home.firstRun.historyImportShown"
        let suite = "SkipOnboardingLaunchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let optedIn = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_ONBOARDING": "1"], arguments: ["cmux"]))
        optedIn.onboarding.showHistoryAtFirstRun(isFirstRun: false, defaults: defaults)
        #expect(defaults.bool(forKey: key))

        for environment in [["CMUX_NEXT_SKIP_ONBOARDING": "1"], [:]] {
            defaults.removeObject(forKey: key)
            let skipping = AppServices(environment: AppEnvironment.current(environment, arguments: ["cmux"]))
            skipping.onboarding.showHistoryAtFirstRun(isFirstRun: true, defaults: defaults)
            #expect(!defaults.bool(forKey: key))
        }
    }
}
