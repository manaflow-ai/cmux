import Foundation
import Testing
import WebKit
@testable import CmuxNextBrowser

/// Incognito windows use an off-the-record browser profile: nothing of it
/// is written to disk, and its data is gone once the profile ends.
@Suite struct OffTheRecordProfileTests {
    final class CountingFactory: WebsiteDataStoreFactory {
        var persistent: [UUID] = []
        var nonPersistent = 0

        func makeStore(identifier: UUID) -> WKWebsiteDataStore {
            persistent.append(identifier)
            return .nonPersistent()
        }

        func makeNonPersistentStore() -> WKWebsiteDataStore {
            nonPersistent += 1
            return .nonPersistent()
        }

        func removeStore(identifier: UUID) async throws {}
    }

    @Test func aProfileIsOffTheRecordFromBeginToEnd() {
        let profiles = OffTheRecordProfiles()
        var ended: [BrowserProfileID] = []
        profiles.observeEnd { ended.append($0) }
        let profile = profiles.begin()
        #expect(profiles.contains(profile))
        #expect(!profiles.contains(.default))
        #expect(profile != .default)
        profiles.end(profile)
        #expect(!profiles.contains(profile))
        profiles.end(profile)
        #expect(ended == [profile])
    }

    /// WebKit: an off-the-record profile gets a non-persistent data store,
    /// never an identified (on-disk) one, and ending the profile drops it.
    @Test func webKitUsesANonPersistentStoreUntilTheProfileEnds() {
        let profiles = OffTheRecordProfiles()
        let factory = CountingFactory()
        let store = WebKitProfileStore(factory: factory, offTheRecord: profiles)
        let incognito = profiles.begin()
        let first = store.dataStore(for: incognito)
        #expect(store.dataStore(for: incognito) === first)
        #expect(factory.persistent.isEmpty)
        #expect(factory.nonPersistent == 1)
        profiles.end(incognito)
        #expect(!store.loadedProfiles.contains(incognito))
        _ = store.dataStore(for: .default)
        #expect(factory.persistent == [BrowserProfileID.default.rawValue])
    }

    /// Site permissions granted in an incognito window stay in memory.
    @Test func sitePermissionsOfAnOffTheRecordProfileNeverReachAFile() {
        let profiles = OffTheRecordProfiles()
        var persisted: [BrowserProfileID] = []
        let registry = SiteSettingsRegistry(persistence: { profile in
            persisted.append(profile)
            return MemorySitePermissionPersistence()
        }, offTheRecord: profiles)
        let incognito = profiles.begin()
        let first = registry.permissions(for: incognito)
        #expect(persisted.isEmpty)
        profiles.end(incognito)
        #expect(registry.permissions(for: incognito) !== first)
        _ = registry.permissions(for: .default)
        #expect(persisted == [.default])
    }

    /// Chromium: an off-the-record store is a shim context key, never a
    /// directory under the Chromium root.
    @Test func chromiumOffTheRecordStoresAreContextKeysNotDirectories() {
        let storage = CEFProfileStorage(root: URL(filePath: "/tmp/cmux-test/Chromium"))
        let id = BrowserProfileID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        #expect(storage.contextKey(for: id, machineKey: nil, offTheRecord: true)
            == "cmux-otr:11111111-2222-3333-4444-555555555555")
        #expect(storage.contextKey(for: id, machineKey: "0a1b", offTheRecord: true)
            == "cmux-otr:11111111-2222-3333-4444-555555555555-m-0a1b")
        #expect(storage.contextKey(for: id, machineKey: nil, offTheRecord: false)
            == "/tmp/cmux-test/Chromium/Profile-11111111-2222-3333-4444-555555555555")
        #expect(storage.isPersistentProfilePath("/tmp/cmux-test/Chromium/Profile-11111111-2222-3333-4444-555555555555"))
        // Chromium reports an off-the-record profile by its parent's path.
        #expect(!storage.isPersistentProfilePath("/tmp/cmux-test/Chromium/Default"))
        #expect(!storage.isPersistentProfilePath("cmux-otr:11111111-2222-3333-4444-555555555555"))
    }
}
