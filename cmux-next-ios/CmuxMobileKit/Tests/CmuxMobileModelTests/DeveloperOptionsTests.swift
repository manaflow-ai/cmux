import Foundation
import Testing
@testable import CmuxMobileModel

/// Production launches remove stored developer settings, and mock content
/// needs the explicit developer switch.
///
/// Serialized: one test writes `UserDefaults.argumentDomain`, which is
/// process-wide, so a test running beside it reads its `setupComplete=NO`
/// over its own suite's stored value (flaked on cmux#51591, run 45367758224).
@Suite(.serialized) struct DeveloperOptionsTests {
    #if canImport(Darwin)
    static let appleUserDefaults = true
    #else
    static let appleUserDefaults = false
    #endif

    @Test func productionSanitizationRemovesEveryDeveloperKey() throws {
        let suite = "cmuxMobile.tests.developer-options.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DeveloperOptions.mockDataKey)
        defaults.set("terminal", forKey: DeveloperOptions.launchDemoKey)
        defaults.set(true, forKey: DeveloperOptions.relayOnlyKey)
        defaults.set("scroll,tui", forKey: DeveloperOptions.terminalDemoPhasesKey)
        defaults.set(true, forKey: "cmuxMobile.setupComplete")

        DeveloperOptions.removeStoredValues(from: defaults)

        for key in DeveloperOptions.storedKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived")
        }
        // Only developer settings go; the person's own state stays.
        #expect(defaults.bool(forKey: "cmuxMobile.setupComplete"))
    }

    /// A launch argument starts setup and setup can still finish it: before
    /// seeding, the argument domain hides the app's own write (the App Review
    /// gate's onboarding walk stayed on "Choose a space").
    /// Apple's argument domain only: swift-corelibs-foundation (the Linux run) keeps a replaced volatile
    /// argument domain's old values, so this runs on the iOS simulator (cmux-next-ios-kit.yml).
    @Test(.enabled(if: Self.appleUserDefaults)) func launchArgumentSeedsSetupCompleteInsteadOfPinningIt() throws {
        let suite = "cmuxMobile.tests.developer-options.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let key = "cmuxMobile.setupComplete"
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        var arguments = original
        arguments[key] = "NO"
        arguments["cmuxMobile.tests.other"] = "YES"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        // The bug: the argument hides setup's write.
        defaults.set(true, forKey: key)
        #expect(!defaults.bool(forKey: key))

        DeveloperOptions.seedLaunchArguments(into: defaults)

        #expect(!defaults.bool(forKey: key), "the launch value is the starting value")
        defaults.set(true, forKey: key)
        #expect(defaults.bool(forKey: key), "setup's write takes effect")
        let after = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        #expect(after[key] == nil)
        #expect(after["cmuxMobile.tests.other"] as? String == "YES", "other launch arguments stay")
    }

    @Test func storedKeysCoverTheDeveloperPage() {
        let keys = Set(DeveloperOptions.storedKeys)
        #expect(keys.isSuperset(of: [DeveloperOptions.mockDataKey, DeveloperOptions.launchDemoKey, DeveloperOptions.relayOnlyKey,
                                     DeveloperOptions.blockUDPKey, DeveloperOptions.forceRelayKey]))
    }

    #if DEBUG
    @Test func mockContentOnlyWithTheExplicitSwitch() {
        #expect(!DeveloperOptions.mockContentEnabled(mockData: false, environment: [:]))
        #expect(!DeveloperOptions.mockContentEnabled(mockData: false, environment: ["CMUX_MOBILE_MOCK_AUTH": "0"]))
        #expect(DeveloperOptions.mockContentEnabled(mockData: true, environment: [:]))
        #expect(DeveloperOptions.mockContentEnabled(mockData: false, environment: ["CMUX_MOBILE_MOCK_AUTH": "1"]))
    }
    #endif

    @MainActor
    @Test func noMacMeansNoMadeUpWorkspace() {
        let backend = UnavailableWorkspaceCreationBackend()
        #expect(!backend.canCreate(on: "mac-studio"))
        #expect(backend.options(on: "mac-studio") == WorkspaceCreationOptions())
    }
}
