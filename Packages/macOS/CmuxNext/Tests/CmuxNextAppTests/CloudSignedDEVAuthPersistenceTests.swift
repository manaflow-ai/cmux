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
        configuration.isProductionAuth = true
        configuration.stackProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
        return configuration
    }

    @Test func productionFallbackTokensAreNotReadAndDevelopmentTokensSurviveRelaunch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSignedDEVAuth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
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
