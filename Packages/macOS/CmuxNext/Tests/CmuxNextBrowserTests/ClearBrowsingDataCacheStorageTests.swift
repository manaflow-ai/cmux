import Foundation
import Testing
@testable import CmuxNextBrowser

/// Clear Browsing Data, the cache option, for a profile Chromium has not opened in this process:
/// the engine moves the profile's cache directories aside and deletes them. A site's service
/// worker keeps the files it fetched in Cache Storage (`Service Worker/CacheStorage`), and that
/// store can grow large. A site can also keep its offline copy there, and the directory holds no
/// times, so it goes only when the range is all time. What a site stored (the worker registrations
/// and scripts, local storage, IndexedDB, an extension's settings) is not a cache and stays.
@MainActor @Suite struct ClearBrowsingDataCacheStorageTests {
    @Test func allTimeRemovesCacheStorageAndKeepsStoredData() async throws {
        let profile = try Self.profileDirectory()
        defer { try? FileManager.default.removeItem(at: profile) }

        await Self.clear(profile, since: nil)

        #expect(!Self.exists("Cache", in: profile), "the HTTP cache is still in the profile")
        #expect(!Self.exists("Service Worker/CacheStorage", in: profile), "Cache Storage is still in the profile")
        for stored in Self.storedData {
            #expect(Self.exists(stored, in: profile), "\(stored) is not a cache and must stay")
        }
    }

    @Test func aShorterRangeKeepsCacheStorage() async throws {
        let profile = try Self.profileDirectory()
        defer { try? FileManager.default.removeItem(at: profile) }

        await Self.clear(profile, since: Self.aTime)

        #expect(!Self.exists("Cache", in: profile), "the HTTP cache goes whole for any range")
        #expect(Self.exists("Service Worker/CacheStorage", in: profile), "a range shorter than all time must keep Cache Storage")
        for stored in Self.storedData {
            #expect(Self.exists(stored, in: profile), "\(stored) is not a cache and must stay")
        }
    }

    /// A quit or a failure in the middle of the delete leaves a moved-aside directory in the
    /// profile. The next clear, of any range, deletes it with its own.
    @Test func aLeftoverOfAnEarlierClearIsDeleted() async throws {
        for since in [nil, Self.aTime] as [Date?] {
            let profile = try Self.profileDirectory()
            defer { try? FileManager.default.removeItem(at: profile) }
            let leftover = profile.appending(path: ".cleared-earlier/origin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: leftover.appending(path: "file"))

            await Self.clear(profile, since: since)

            let aside = try FileManager.default.contentsOfDirectory(atPath: profile.path).filter { $0.hasPrefix(".cleared-") }
            #expect(aside.isEmpty, "moved-aside directories are still in the profile (all time: \(since == nil)): \(aside)")
        }
    }

    // MARK: Fixtures

    /// The start of a range shorter than all time.
    private static let aTime = Date(timeIntervalSince1970: 1_700_000_000)

    /// Directories of a Chromium profile that hold what a site or an extension stored.
    private static let storedData = ["Service Worker/Database", "Service Worker/ScriptCache", "Local Storage/leveldb", "IndexedDB",
                                     "Local Extension Settings/extension"]

    /// The clear, and its delete off the main thread to the end.
    private static func clear(_ profile: URL, since: Date?) async {
        _ = await CEFEngine.removeCaches(in: profile, since: since)?.value
    }

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
