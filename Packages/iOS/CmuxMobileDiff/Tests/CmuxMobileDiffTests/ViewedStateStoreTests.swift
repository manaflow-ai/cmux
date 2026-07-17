import Foundation
import Testing

@testable import CmuxMobileDiff

@Suite struct ViewedStateStoreTests {
    @Test func digestParticipatesInKeyIdentity() {
        let old = ViewedFileKey(workspaceID: "workspace", path: "App.swift", patchDigest: "old")
        let new = ViewedFileKey(workspaceID: "workspace", path: "App.swift", patchDigest: "new")
        #expect(old != new)
    }

    @Test func digestChangeInvalidatesViewedState() {
        let defaults = makeDefaults()
        var store = ViewedStateStore(defaults: defaults)
        let old = ViewedFileKey(workspaceID: "workspace", path: "App.swift", patchDigest: "old")
        let new = ViewedFileKey(workspaceID: "workspace", path: "App.swift", patchDigest: "new")
        store.setViewed(true, for: old)
        #expect(store.isViewed(old))
        #expect(!store.isViewed(new))
    }

    @Test func persistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let key = ViewedFileKey(workspaceID: "workspace", path: "App.swift", patchDigest: "digest")
        var store = ViewedStateStore(defaults: defaults)
        store.setViewed(true, for: key)
        #expect(ViewedStateStore(defaults: defaults).isViewed(key))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ViewedStateStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
