import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing
@testable import CmuxNextCloud

struct CloudSignedDEVAuthPersistenceTests {
    private var development: CloudConfiguration {
        CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
    }

    private var previousProduction: CloudConfiguration {
        var configuration = development
        if var selection = configuration.runtimeSelection {
            selection.authNamespace = "production-fixture"
            selection.legacyStorage = true
            selection.authStorageNamespace = nil
            configuration.runtimeSelection = selection
        }
        configuration.isProductionAuth = true
        configuration.stackProjectID = "production-fixture"
        return configuration
    }

    @Test func productionFallbackTokensAreNotReadAndDevelopmentTokensSurviveRelaunch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSignedDEVAuth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(previousProduction.keychainService == "com.cmuxterm.app.debug.next.auth")
        #expect(development.keychainService == "com.cmuxterm.app.debug.next.auth.fixture")
        #expect(development.runtimeSelection?.storageNamespace == nil, "existing iPhone and install paths survive the update")
        let old = FileStackTokenStore(directory: previousProduction.credentialsDirectory(homeDirectory: home))
        await old.setTokens(accessToken: "production-access", refreshToken: "production-refresh")

        let firstLaunch = FileStackTokenStore(directory: development.credentialsDirectory(homeDirectory: home))
        #expect(await firstLaunch.getStoredAccessToken() == nil)
        #expect(await firstLaunch.getStoredRefreshToken() == nil)
        #expect(development.keychainService != previousProduction.keychainService)
        await firstLaunch.setTokens(accessToken: "development-access", refreshToken: "development-refresh")

        let nextLaunch = FileStackTokenStore(directory: development.credentialsDirectory(homeDirectory: home))
        #expect(await nextLaunch.getStoredAccessToken() == "development-access")
        #expect(await nextLaunch.getStoredRefreshToken() == "development-refresh")
        let retainedProduction = FileStackTokenStore(directory: previousProduction.credentialsDirectory(homeDirectory: home))
        #expect(await retainedProduction.getStoredAccessToken() == "production-access")
        #expect(await retainedProduction.getStoredRefreshToken() == "production-refresh")
    }

    @Test func existingSignedDEVTokensSurviveUpgradeButAnExplicitSwitchDoesNotAdoptThem() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSignedDEVUpgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let historicalDirectory = home.appendingPathComponent("Library/Application Support/cmux/com.cmuxterm.app.debug.next/fixture")
        let historical = FileStackTokenStore(directory: historicalDirectory)
        await historical.setTokens(accessToken: "existing-development-access", refreshToken: "existing-development-refresh")
        let upgraded = FileStackTokenStore(directory: development.credentialsDirectory(homeDirectory: home))
        #expect(await upgraded.getStoredAccessToken() == "existing-development-access")
        #expect(await upgraded.getStoredRefreshToken() == "existing-development-refresh")
        var switched = development
        var selection = try #require(switched.runtimeSelection)
        selection.legacyStorage = false
        selection.authNamespace = "explicit-backend-switch"
        switched.runtimeSelection = selection
        let isolated = FileStackTokenStore(directory: switched.credentialsDirectory(homeDirectory: home))
        #expect(await isolated.getStoredAccessToken() == nil)
        #expect(await isolated.getStoredRefreshToken() == nil)
        #expect(switched.keychainService != development.keychainService)
        #expect(await historical.getStoredAccessToken() == "existing-development-access")
    }

    @MainActor @Test func productionIdentityDoesNotPrimeDevelopmentAndDevelopmentIdentitySurvivesRelaunch() throws {
        let name = "CloudSignedDEVAuth-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try saveIdentity(project: previousProduction, defaults: defaults, user: "production-user", team: "production-team")

        let firstLaunch = CloudAuth(configuration: development, environment: [:], defaults: defaults)
        #expect(!firstLaunch.isSignedIn)
        #expect(!firstLaunch.isRestoring)
        #expect(firstLaunch.user == nil)
        #expect(firstLaunch.coordinator.selectedTeamID == nil)

        try saveIdentity(project: development, defaults: defaults, user: "development-user", team: "development-team")
        let nextLaunch = CloudAuth(configuration: development, environment: [:], defaults: defaults)
        #expect(nextLaunch.isSignedIn)
        #expect(nextLaunch.user?.id == "development-user")
        #expect(nextLaunch.coordinator.selectedTeamID == "development-team")
        #expect(defaults.string(forKey: "cmux.auth.selectedTeamID") == "production-team")
    }

    private func saveIdentity(project: CloudConfiguration, defaults: UserDefaults, user: String, team: String) throws {
        CMUXAuthSessionCache(keyValueStore: defaults, key: project.authDefaultsKey("cmux.auth.hasTokens")).setHasTokens(true)
        try CMUXAuthIdentityStore(keyValueStore: defaults, key: project.authDefaultsKey("cmux.auth.cachedUser"))
            .save(CMUXAuthUser(id: user, primaryEmail: nil, displayName: nil))
        CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: project.authDefaultsKey("cmux.auth.selectedTeamID")).selectedTeamID = team
    }
}
