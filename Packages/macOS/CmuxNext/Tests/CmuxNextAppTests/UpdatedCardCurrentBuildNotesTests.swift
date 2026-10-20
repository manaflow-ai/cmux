@testable import CmuxNextUpdater
import Foundation
import Testing

/// The "cmux Updated!" card lists real changes even when the update record
/// has none (2026-10-20, Lawrence on "Updated to nightly 3939068 / What's new
/// in this build": "not descriptive enough at all"). Build 3939068's signed
/// notes had six What's New entries; the card showed none because it read
/// only the record. It now reads this build's own notes.
@MainActor @Suite(.serialized) struct UpdatedCardCurrentBuildNotesTests {
    nonisolated static let build = "3939068198101"
    nonisolated static let version = "1.0.0-nightly.3939068198101"

    nonisolated static func notes() -> ReleaseNotes {
        ReleaseNotes(version: 1, build: build, shortVersion: version, date: "2026-10-20", highlights: [],
                     changes: ["fix(home-sidebar): pinned avatars match row avatars in the compact rail"],
                     summary: [.init(group: "fixed", title: "Pinned avatars match row avatars in the compact rail"),
                               .init(group: "new", title: "A Chief with no avatar of its own shows 🫡")])
    }

    /// An updated launch with no record: the last version seen is older than this one.
    static func updater(loads: @escaping @Sendable (String) async -> ReleaseNotes?) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.updated-card-notes", shortVersion: version,
                                           build: build, minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
                                           hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "UpdatedCardCurrentBuildNotesTests.\(UUID().uuidString)")!
        defaults.set("1.0.0-nightly.3938998689001", forKey: "cmux.next.whatsNew.lastSeenVersion")
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.notesLoader = loads
        updater.whatsNew.load()
        return updater
    }

    @Test func anUpdateWithoutARecordListsThisBuildsChanges() async throws {
        let updater = Self.updater { build in build == Self.build ? Self.notes() : nil }
        #expect(updater.whatsNew.isUpdated)
        let task = try #require(updater.loadCurrentBuildNotesIfNeeded())
        await task.value
        let card = try #require(updater.updatedWithoutRecordHighlights)
        #expect(card.items.map(\.title) == ["Pinned avatars match row avatars in the compact rail",
                                           "A Chief with no avatar of its own shows 🫡"])
        #expect(card.date == "2026-10-20")
    }

    @Test func notesAreReadOncePerLaunch() async throws {
        let reads = ReadCount()
        let updater = Self.updater { _ in await reads.bump(); return Self.notes() }
        await updater.loadCurrentBuildNotesIfNeeded()?.value
        #expect(updater.loadCurrentBuildNotesIfNeeded() == nil)
        #expect(await reads.value == 1)
    }

    actor ReadCount {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}
