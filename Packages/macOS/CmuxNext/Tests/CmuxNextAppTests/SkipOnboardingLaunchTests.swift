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
        #expect(launch.launchSteps.skipsFirstRun)
        #expect(!launch.showcase)
    }

    @Test func aPlainLaunchShowsNoOnboarding() {
        #expect(AppEnvironment.current([:], arguments: ["cmux"]).launchSteps.skipsFirstRun)
    }

    @Test(arguments: [
        (["CMUX_NEXT_ONBOARDING": "1"], ["cmux"]),
        ([String: String](), ["cmux", "--onboarding"]),
    ])
    func theOptInBringsOnboardingBack(environment: [String: String], arguments: [String]) {
        #expect(!AppEnvironment.current(environment, arguments: arguments).launchSteps.skipsFirstRun)
    }

    /// A fresh profile on a plain launch: the first run starts no Set Up cmux card, and a card left pending by an
    /// earlier build no longer shows.
    @Test func aFreshProfileGetsNoSetupCard() throws {
        let suite = "SkipOnboardingLaunchTests.card.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plain = AppEnvironment.current([:], arguments: ["cmux"])

        let fresh = FirstRunSetup(defaults: defaults, skipsOnboarding: plain.launchSteps.skipsFirstRun)
        #expect(!fresh.begin(isFirstRun: true, replacedKeys: ["cli.install.offeredAtLaunch"]))
        #expect(!fresh.shows)

        defaults.set("pending", forKey: FirstRunSetup.stateKey)
        #expect(!FirstRunSetup(defaults: defaults, skipsOnboarding: plain.launchSteps.skipsFirstRun).shows)
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

    /// A new person's first launch opens a new agent chat once (cmux#48416): a plain launch and the onboarding
    /// opt-in do, a capture build or the showcase never does, a relaunch (no first run) never does, and an
    /// install that already opened it never opens it again.
    @Test func theFirstRunChatOpensOncePerInstallButNeverForCaptureBuilds() async throws {
        _ = NSApplication.shared
        let suite = "SkipOnboardingLaunchTests.firstChat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plain = AppEnvironment.current([:], arguments: ["cmux"]).launchSteps
        let optedIn = AppEnvironment.current(["CMUX_NEXT_ONBOARDING": "1"], arguments: ["cmux"]).launchSteps
        let capture = AppEnvironment.current(["CMUX_NEXT_SKIP_ONBOARDING": "1"], arguments: ["cmux"]).launchSteps
        let showcase = AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"], arguments: ["cmux"]).launchSteps

        #expect(OnboardingService.opensFirstChat(isFirstRun: true, steps: plain, defaults: defaults))
        #expect(OnboardingService.opensFirstChat(isFirstRun: true, steps: optedIn, defaults: defaults))
        #expect(!OnboardingService.opensFirstChat(isFirstRun: true, steps: capture, defaults: defaults))
        #expect(!OnboardingService.opensFirstChat(isFirstRun: true, steps: showcase, defaults: defaults))
        #expect(!OnboardingService.opensFirstChat(isFirstRun: false, steps: plain, defaults: defaults))

        // Under the capture flag the launch asks for nothing and leaves the install's first chat for later.
        let skipping = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SKIP_ONBOARDING": "1"], arguments: ["cmux"]))
        #expect(await skipping.onboarding.openFirstChat(isFirstRun: true, defaults: defaults) == nil)
        #expect(!defaults.bool(forKey: OnboardingService.firstChatOpenedKey))

        defaults.set(true, forKey: OnboardingService.firstChatOpenedKey)
        #expect(!OnboardingService.opensFirstChat(isFirstRun: true, steps: plain, defaults: defaults))
    }
}
