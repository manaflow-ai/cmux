import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium profile storage")
struct BrowserChromiumProfileStorageTests {
    private let support = URL(fileURLWithPath: "/Users/u/Library/Application Support", isDirectory: true)

    @Test func rootIsPerBundleIdentifierSoTagsNeverShareData() {
        let release = BrowserChromiumProfileStorage.forApplication(bundleIdentifier: "com.cmuxterm.app", applicationSupport: support)
        let tagA = BrowserChromiumProfileStorage.forApplication(bundleIdentifier: "com.cmuxterm.app.debug.a", applicationSupport: support)
        let tagB = BrowserChromiumProfileStorage.forApplication(bundleIdentifier: "com.cmuxterm.app.debug.b", applicationSupport: support)
        #expect(release.root.path == "/Users/u/Library/Application Support/com.cmuxterm.app/Chromium")
        #expect(tagA.root.path == "/Users/u/Library/Application Support/com.cmuxterm.app.debug.a/Chromium")
        #expect(Set([release.root, tagA.root, tagB.root]).count == 3)
    }

    @Test(arguments: [nil, "", "  ", "../escape", "a/b", ".hidden"])
    func unusableBundleIdentifierFallsBackToReleaseIdentifier(_ identifier: String?) {
        let storage = BrowserChromiumProfileStorage.forApplication(bundleIdentifier: identifier, applicationSupport: support)
        #expect(storage.root.path == "/Users/u/Library/Application Support/com.cmuxterm.app/Chromium")
    }

    @Test func everyProfileIncludingDefaultGetsDirectChildOfRoot() {
        let storage = BrowserChromiumProfileStorage(root: URL(fileURLWithPath: "/r/Chromium"))
        let defaultPath = storage.cachePath(forProfileID: BrowserProfileRepository.builtInDefaultProfileID)
        let other = UUID()
        let otherPath = storage.cachePath(forProfileID: other)
        #expect(defaultPath.deletingLastPathComponent().path == storage.root.path)
        #expect(otherPath.deletingLastPathComponent().path == storage.root.path)
        #expect(otherPath.lastPathComponent == "Profile-" + other.uuidString)
        #expect(defaultPath != otherPath)
    }

    @Test func profileIDRoundTripsOnlyForDirectPersistentChildren() {
        let storage = BrowserChromiumProfileStorage(root: URL(fileURLWithPath: "/r/Chromium"))
        let id = UUID()
        #expect(storage.profileID(forCachePath: storage.cachePath(forProfileID: id).path) == id)
        #expect(storage.profileID(forCachePath: "/r/Chromium/Profile-\(id.uuidString)/") == id)
        #expect(storage.profileID(forCachePath: "/r/Chromium") == nil)
        #expect(storage.profileID(forCachePath: "/r/Chromium/nested/Profile-\(id.uuidString)") == nil)
        #expect(storage.profileID(forCachePath: "/r/Chromium/Profile-\(id.uuidString)-m-ab") == nil)
        #expect(storage.profileID(forCachePath: "/r/Chromium/Profile-not-a-uuid") == nil)
        #expect(storage.profileID(forCachePath: "relative/Profile-\(id.uuidString)") == nil)
        #expect(storage.profileID(forCachePath: "/r/Chromium/../Chromium/Profile-\(id.uuidString)") == id)
    }

    @Test func cacheDirectoriesLiveInsideTheProfileStore() {
        let storage = BrowserChromiumProfileStorage(root: URL(fileURLWithPath: "/r/Chromium"))
        let id = UUID()
        let caches = storage.cacheDirectories(forProfileID: id)
        #expect(caches.count == BrowserChromiumProfileStorage.cacheDirectoryNames.count)
        #expect(caches.allSatisfy { $0.deletingLastPathComponent() == storage.cachePath(forProfileID: id) })
    }
}

@Suite("Chromium profile storage cleanup") @MainActor
struct BrowserChromiumProfileStorageCleanupTests {
    private func makeCleanup() throws -> (BrowserChromiumProfileStorageCleanup, URL, UserDefaults) {
        let suite = "cmux.chromium.cleanup.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chromium-\(UUID().uuidString)/Chromium", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (BrowserChromiumProfileStorageCleanup(storage: BrowserChromiumProfileStorage(root: root), defaults: defaults), root, defaults)
    }

    @Test func unopenedDeletedProfileIsRemovedAndOpenedOneWaitsForNextLaunch() throws {
        let (cleanup, root, _) = try makeCleanup()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let closed = UUID(), opened = UUID()
        for id in [closed, opened] {
            try FileManager.default.createDirectory(at: cleanup.storage.cachePath(forProfileID: id), withIntermediateDirectories: true)
            cleanup.markDeleted(id)
        }
        let removable = cleanup.takeRemovable { $0 == opened }
        #expect(removable == [cleanup.storage.cachePath(forProfileID: closed)])
        #expect(cleanup.pendingProfileIDs == [opened])
        BrowserChromiumProfileStorageCleanup.removeDirectories(removable)
        #expect(!FileManager.default.fileExists(atPath: cleanup.storage.cachePath(forProfileID: closed).path))
        #expect(FileManager.default.fileExists(atPath: cleanup.storage.cachePath(forProfileID: opened).path))

        // Next launch: nothing is opened yet.
        let next = cleanup.takeRemovable { _ in false }
        #expect(next == [cleanup.storage.cachePath(forProfileID: opened)])
        #expect(cleanup.pendingProfileIDs.isEmpty)
    }

    @Test func builtInDefaultIsNeverMarkedAndDuplicatesCollapse() throws {
        let (cleanup, root, _) = try makeCleanup()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        cleanup.markDeleted(BrowserProfileRepository.builtInDefaultProfileID)
        let id = UUID()
        cleanup.markDeleted(id)
        cleanup.markDeleted(id)
        #expect(cleanup.pendingProfileIDs == [id])
    }

    @Test func pendingListSurvivesARelaunch() throws {
        let (cleanup, root, defaults) = try makeCleanup()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let id = UUID()
        cleanup.markDeleted(id)
        let relaunched = BrowserChromiumProfileStorageCleanup(storage: cleanup.storage, defaults: defaults)
        #expect(relaunched.pendingProfileIDs == [id])
    }

    @Test func removeCachesKeepsCookiesAndLeftoversAreSwept() throws {
        let (cleanup, root, _) = try makeCleanup()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let id = UUID()
        let profile = cleanup.storage.cachePath(forProfileID: id)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("GPUCache"), withIntermediateDirectories: true)
        try Data().write(to: profile.appendingPathComponent("Cookies"))
        #expect(BrowserChromiumProfileStorageCleanup.removeCaches(ofProfileID: id, in: cleanup.storage))
        #expect(!FileManager.default.fileExists(atPath: profile.appendingPathComponent("Cache").path))
        #expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Cookies").path))
        #expect(!BrowserChromiumProfileStorageCleanup.removeCaches(ofProfileID: id, in: cleanup.storage))

        let leftover = root.appendingPathComponent(".deleted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        BrowserChromiumProfileStorageCleanup.removeLeftovers(in: cleanup.storage)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: profile.path))
    }
}
