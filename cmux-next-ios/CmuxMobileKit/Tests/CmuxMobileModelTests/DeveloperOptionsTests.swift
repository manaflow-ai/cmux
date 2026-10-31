import Foundation
import Testing
@testable import CmuxMobileModel

/// Production launches remove stored developer settings, and mock content
/// needs the explicit developer switch.
@Suite struct DeveloperOptionsTests {
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

    @Test func storedKeysCoverTheDeveloperPage() {
        let keys = Set(DeveloperOptions.storedKeys)
        #expect(keys.isSuperset(of: [DeveloperOptions.mockDataKey, DeveloperOptions.launchDemoKey, DeveloperOptions.relayOnlyKey]))
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
