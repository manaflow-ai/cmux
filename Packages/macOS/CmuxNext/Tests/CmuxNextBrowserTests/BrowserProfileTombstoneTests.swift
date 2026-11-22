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

    /// One cleanup per deleted id: a second pass skips an id still in flight and an id whose store an
    /// engine opened, and claims the in-flight one again only after its cleanup released it.
    @Test func aCleanupClaimsEachDeletedIDOnceUntilItIsReleased() {
        var claims = BrowserProfileCleanupClaims()
        let opened = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let openedProfile = BrowserProfileRecord.engineProfile(for: opened)
        let isOpen: (BrowserProfileID) -> Bool = { $0 == openedProfile }
        #expect(claims.claim([id, opened], isOpen: isOpen) == [id])
        #expect(claims.inFlight == [id])
        #expect(claims.claim([id, opened], isOpen: isOpen).isEmpty, "an in-flight id gets no second cleanup")
        claims.release([id])
        #expect(claims.inFlight.isEmpty)
        #expect(claims.claim([id], isOpen: isOpen) == [id])
    }

    /// The daemon-backed create runs the same check as the book's own create.
    @Test func requireReusableRefusesOnlyAPendingDeletion() throws {
        var book = BrowserProfileBook()
        _ = try book.create(id: id, name: "First", color: nil, icon: nil)
        try book.requireReusable(id)
        try book.delete(id)
        #expect(throws: BrowserProfileBookError.pendingCleanup) { try book.requireReusable(id) }
        book.finishCleanup([id])
        try book.requireReusable(id)
    }

    /// An import whose id still waits for a deleted profile's data keeps the migration ticket (false);
    /// the others still migrate, invalid ids are skipped, and each failure's reason reaches the log.
    @MainActor @Test func importMigrationWaitsForAPendingDeletion() async {
        struct Failure: Error {}
        let other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", broken = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        var migrated: [String] = [], failures: [String] = []
        let finished = await BrowserProfileBook.migrateImports([id, "not an id", other, broken], id: { $0 }, migrate: { record in
            if record == id { throw BrowserProfileBookError.pendingCleanup }
            if record == broken { throw Failure() }
            migrated.append(record)
        }, failed: { record, reason in failures.append("\(record): \(reason)") })
        #expect(!finished)
        #expect(migrated == [other])
        #expect(failures == ["\(id): browser profile is pending deletion", "\(broken): Failure()"])
        #expect(await BrowserProfileBook.migrateImports([other], id: { $0 }, migrate: { _ in }, failed: { _, _ in }))
    }
}
