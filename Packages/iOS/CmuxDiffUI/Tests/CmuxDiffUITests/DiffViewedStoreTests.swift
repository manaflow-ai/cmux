import Foundation
import Testing
@testable import CmuxDiffUI

@Suite struct DiffViewedStoreTests {
    @Test func exactWorkspacePathAndDigestRoundTrip() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.suiteName) }
        let store = DiffViewedStore(defaults: environment.defaults)

        store.setViewed(true, workspaceID: "workspace", path: "Sources/App.swift", patchDigest: "v1")

        #expect(store.isViewed(workspaceID: "workspace", path: "Sources/App.swift", patchDigest: "v1"))
        #expect(!store.isViewed(workspaceID: "other", path: "Sources/App.swift", patchDigest: "v1"))
        #expect(!store.isViewed(workspaceID: "workspace", path: "Other.swift", patchDigest: "v1"))
    }

    @Test func changedPatchDigestInvalidatesViewedState() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.suiteName) }
        let store = DiffViewedStore(defaults: environment.defaults)

        store.setViewed(true, workspaceID: "workspace", path: "App.swift", patchDigest: "old")

        #expect(store.isViewed(workspaceID: "workspace", path: "App.swift", patchDigest: "old"))
        #expect(!store.isViewed(workspaceID: "workspace", path: "App.swift", patchDigest: "new"))
    }

    @Test func clearingViewedStatePersists() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.suiteName) }
        let store = DiffViewedStore(defaults: environment.defaults)
        store.setViewed(true, workspaceID: "workspace", path: "App.swift", patchDigest: "v1")

        store.setViewed(false, workspaceID: "workspace", path: "App.swift", patchDigest: "v1")
        let reloaded = DiffViewedStore(defaults: environment.defaults)

        #expect(!reloaded.isViewed(workspaceID: "workspace", path: "App.swift", patchDigest: "v1"))
    }

    private func makeEnvironment() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "DiffViewedStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
