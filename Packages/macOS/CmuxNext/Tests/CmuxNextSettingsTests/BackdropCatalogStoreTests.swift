import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import os
import Testing

/// The wallpaper grid's catalog is listed off the main actor (``BackdropCatalogStore``): the
/// Settings page's host lists read the last listing, and a listing that lands updates them. It
/// was listed on the main actor on every host-lists read (sweep 2026-10-23: `AppleWallpapers.pictures`
/// and `AppleWallpaper.init` in 35 main-thread stalls, up to 190 ms in STRESS).
@MainActor
struct BackdropCatalogStoreTests {
    /// A lister that records each call and whether it ran on the main thread, and returns a
    /// catalog of `folder`'s one picture.
    final class Lister: Sendable {
        let calls = OSAllocatedUnfairLock(initialState: [Bool]())
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("backdrop-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("Blue Hour.png"))
        }

        var list: @Sendable () -> BackdropCatalog {
            { [self] in
                calls.withLock { $0.append(Thread.isMainThread) }
                return BackdropCatalog(systemDirectory: folder, fileManager: .default, assets: .none,
                                       aerials: folder.appendingPathComponent("aerials", isDirectory: true))
            }
        }
    }

    @Test func aReadListsNothingAndARefreshListsOffTheMainThread() async throws {
        let lister = try Lister()
        defer { try? FileManager.default.removeItem(at: lister.folder) }
        let store = BackdropCatalogStore(list: lister.list)

        // Reads are stored values: no folder is read for them.
        #expect(store.catalog == .unlisted)
        _ = store.pageRows
        #expect(lister.calls.withLock { $0 }.isEmpty)

        store.refresh()
        await store.settle()
        #expect(lister.calls.withLock { $0 } == [false], "one listing, off the main thread")
        #expect(store.catalog.choices.contains(.system(path: lister.folder.appendingPathComponent("Blue Hour.png").path)))
        #expect(store.pageRows == store.catalog.pageRows)
    }

    /// Refreshes while a listing runs list once more after it, not once each.
    @Test func refreshesDuringAListingListOnceMore() async throws {
        let lister = try Lister()
        defer { try? FileManager.default.removeItem(at: lister.folder) }
        let store = BackdropCatalogStore(list: lister.list)

        store.refresh()
        store.refresh()
        store.refresh()
        await store.settle()
        #expect(store.listings == 2)
        #expect(lister.calls.withLock { $0.count } == 2)
    }
}
