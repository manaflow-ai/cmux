import CmuxNextBrowser
import Foundation
import Testing

/// SW-08: deleting a browser profile owns the exact engine data directories
/// until both Chromium and WebKit cleanup finish. A recreated import may
/// legitimately request its old UUID; it must wait for deletion to finish.
@Suite struct BrowserProfileTombstoneTests {
    private let id = "12345678-1234-4234-8234-123456789abc"

    @Test func aDeletedIDCannotReenterWhileItsDataIsPendingRemoval() throws {
        var book = BrowserProfileBook()
        let original = try book.create(id: id, name: "First", color: nil, icon: nil)
        #expect(original.engineProfile != .default)
        try book.delete(id)
        #expect(book.record(id) == nil)
        #expect(book.pendingCleanup == [id])
        #expect(book.engineProfile(for: id) == .default)

        #expect(throws: BrowserProfileBookError.pendingCleanup) {
            try book.create(id: id, name: "Second", color: nil, icon: nil)
        }
        #expect(book.record(id) == nil)
        #expect(book.pendingCleanup == [id], "a failed recreation must retain the tombstone")
    }

    @Test func recreatingTheSameIDAfterCleanupGetsItsOwnFreshStore() throws {
        var book = BrowserProfileBook()
        _ = try book.create(id: id, name: "First", color: nil, icon: nil)
        try book.delete(id)
        book.finishCleanup([id])
        #expect(book.pendingCleanup.isEmpty)
        let recreated = try book.create(id: id, name: "Second", color: nil, icon: nil)
        #expect(recreated.name == "Second")
        #expect(recreated.engineProfile != .default)
        #expect(book.engineProfile(for: id) == recreated.engineProfile)
        #expect(book.pendingCleanup.isEmpty)
    }

    @Test func aPendingDeletionSurvivesFileRoundtripUntilCleanupFinishes() throws {
        var book = BrowserProfileBook()
        _ = try book.create(id: id, name: "Private", color: nil, icon: nil)
        try book.delete(id)
        let data = try JSONEncoder().encode(book)
        var restored = try JSONDecoder().decode(BrowserProfileBook.self, from: data)
        #expect(restored.pendingCleanup == [id])
        #expect(throws: BrowserProfileBookError.pendingCleanup) {
            try restored.create(id: id, name: "Import Retry", color: nil, icon: nil)
        }
        restored.finishCleanup([id])
        #expect(try restored.create(id: id, name: "Import Retry", color: nil, icon: nil).name == "Import Retry")
    }

    @Test func anotherIDAndAnExistingLiveIDKeepTheirNormalBehavior() throws {
        var book = BrowserProfileBook()
        let live = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        _ = try book.create(id: id, name: "Deleted", color: nil, icon: nil)
        _ = try book.create(id: live, name: "Live", color: nil, icon: nil)
        try book.delete(id)
        let existing = try book.create(id: live, name: "Ignored retry", color: nil, icon: nil)
        #expect(existing.name == "Live")
        let fresh = try book.create(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "Fresh", color: nil, icon: nil)
        #expect(fresh.name == "Fresh")
        #expect(book.pendingCleanup == [id])
    }
}
