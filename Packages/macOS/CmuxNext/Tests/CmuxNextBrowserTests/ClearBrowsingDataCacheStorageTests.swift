import Foundation
import Testing
@testable import CmuxNextBrowser

/// Clear Browsing Data, the cache option, for a profile Chromium has not opened in this process:
/// the engine moves the profile's cache directories aside. A site's service worker keeps the files
/// it fetched in Cache Storage (`Service Worker/CacheStorage`), and that store can grow large.
/// It is a cache, and the WebKit side clears the same kind with the same option, so it goes with
/// the HTTP cache. What a site stored (the worker registrations, IndexedDB, an extension's
/// settings) is not a cache and stays.
@MainActor @Suite struct ClearBrowsingDataCacheStorageTests {
    @Test func theCacheOptionRemovesCacheStorageAndKeepsStoredData() throws {
        let profile = try Self.profileDirectory()
        defer { try? FileManager.default.removeItem(at: profile) }

        CEFEngine.removeCaches(in: profile)

        #expect(!Self.exists("Cache", in: profile), "the HTTP cache is still in the profile")
        #expect(!Self.exists("Service Worker/CacheStorage", in: profile), "Cache Storage is still in the profile")
        for stored in Self.storedData {
            #expect(Self.exists(stored, in: profile), "\(stored) is not a cache and must stay")
        }
    }

    // MARK: Fixtures

    /// Directories of a Chromium profile that hold what a site or an extension stored.
    private static let storedData = ["Service Worker/Database", "IndexedDB", "Local Extension Settings/extension"]

    /// A directory laid out as a Chromium profile: two caches and the stored data, one file in each.
    private static func profileDirectory() throws -> URL {
        let manager = FileManager.default
        let profile = manager.temporaryDirectory.appending(path: "clear-cache-storage-\(UUID().uuidString)",
                                                           directoryHint: .isDirectory)
        for name in ["Cache/Cache_Data", "Service Worker/CacheStorage/origin/cache"] + storedData {
            let directory = profile.appending(path: name, directoryHint: .isDirectory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appending(path: "file"))
        }
        return profile
    }

    private static func exists(_ name: String, in profile: URL) -> Bool {
        FileManager.default.fileExists(atPath: profile.appending(path: name).path)
    }
}
