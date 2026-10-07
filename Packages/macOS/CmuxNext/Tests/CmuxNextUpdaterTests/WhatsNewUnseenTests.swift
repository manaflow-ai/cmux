import Foundation
import Testing
@testable import CmuxNextUpdater

/// WHATS-NEW-AFTER-UPDATE W1/W4: a fresh install shows nothing; an update
/// to a version with notes shows the item; a multi-version jump shows every
/// missed version, newest first; opening the page clears it, and the record
/// survives a relaunch (a new center over the same defaults).
@MainActor
@Suite struct WhatsNewUnseenTests {
    let documents = ["0.64.0", "0.65.0", "0.66.0", "0.67.0"].map { WhatsNewFixtures.document($0) }

    private func center(_ version: String, _ defaults: UserDefaults, sources: [any WhatsNewSource]? = nil) -> WhatsNewCenter {
        WhatsNewCenter(currentVersion: version, defaults: defaults, sources: sources ?? [StubWhatsNewSource(documents)])
    }

    @Test func aFreshInstallShowsNothing() async {
        let defaults = WhatsNewFixtures.defaults()
        let first = center("0.66.0", defaults)
        await first.load().value
        #expect(first.unseen.isEmpty)
        #expect(!first.showsItem)
        #expect(defaults.string(forKey: WhatsNewSeenStore.lastSeenKey) == "0.66.0")
    }

    @Test func anUpdateToAVersionWithNotesShowsTheItem() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.65.0", defaults).load().value
        let updated = center("0.66.0", defaults)
        await updated.load().value
        #expect(updated.unseen.map(\.version) == ["0.66.0"])
        #expect(updated.showsItem)
    }

    @Test func aMultiVersionJumpShowsEveryMissedVersionNewestFirst() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.64.0", defaults).load().value
        let jumped = center("0.67.0", defaults)
        await jumped.load().value
        #expect(jumped.unseen.map(\.version) == ["0.67.0", "0.66.0", "0.65.0"])
    }

    @Test func openingThePageClearsTheItemAndTheRecordSurvivesARelaunch() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.64.0", defaults).load().value
        let updated = center("0.66.0", defaults)
        await updated.load().value
        let shown = updated.open()
        #expect(shown.map(\.version) == ["0.66.0", "0.65.0"])
        #expect(updated.presented == shown)
        #expect(!updated.showsItem)
        let relaunched = center("0.66.0", defaults)
        await relaunched.load().value
        #expect(relaunched.unseen.isEmpty)
        // Opened again from the palette with nothing unseen: the recent notes.
        #expect(relaunched.open().map(\.version) == ["0.66.0", "0.65.0", "0.64.0"])
    }

    @Test func notOpeningKeepsTheItemAcrossUpdates() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.64.0", defaults).load().value
        await center("0.65.0", defaults).load().value
        let later = center("0.66.0", defaults)
        await later.load().value
        #expect(later.unseen.map(\.version) == ["0.66.0", "0.65.0"])
    }

    @Test func theSettingHidesTheItemButKeepsTheNotes() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.65.0", defaults).load().value
        let updated = center("0.66.0", defaults)
        await updated.load().value
        updated.isItemEnabled = false
        #expect(!updated.showsItem)
        #expect(updated.open().map(\.version) == ["0.66.0"])
    }

    @Test func aRollbackShowsNothingAndKeepsTheNewerRecord() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.66.0", defaults).load().value
        center("0.66.0", defaults).open()
        let rolledBack = center("0.65.0", defaults)
        await rolledBack.load().value
        #expect(rolledBack.unseen.isEmpty)
        rolledBack.open()
        #expect(defaults.string(forKey: WhatsNewSeenStore.lastSeenKey) == "0.66.0")
    }

    @Test func aVersionWithoutNotesOrEntriesShowsNothing() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.67.0", defaults, sources: [StubWhatsNewSource([])]).load().value
        let empty = center("0.68.0", defaults, sources: [StubWhatsNewSource([WhatsNewFixtures.document("0.68.0", entries: 0)])])
        await empty.load().value
        #expect(empty.unseen.isEmpty)
    }

    /// The retired card recorded the last launched build; the first launch
    /// with this change reads it, so a nightly update right after it shows.
    @Test func theRetiredCardsRecordCountsAsLastSeen() async {
        let defaults = WhatsNewFixtures.defaults()
        defaults.set("41", forKey: WhatsNewSeenStore.legacyLastSeenBuildKey)
        let nightly = center("1.0.0-nightly.42", defaults, sources: [
            StubWhatsNewSource([WhatsNewFixtures.document("1.0.0-nightly.42", channel: .nightly, origin: .feed)], readsNetwork: true),
        ])
        await nightly.load().value
        #expect(nightly.unseen.map(\.version) == ["1.0.0-nightly.42"])
    }

    /// A network source is asked only for the unseen range; a bundled copy
    /// of a version wins over a feed copy.
    @Test func networkSourcesReadOnlyTheUnseenRangeAndBundledCopiesWin() async {
        let defaults = WhatsNewFixtures.defaults()
        await center("0.65.0", defaults, sources: []).load().value
        let feed = StubWhatsNewSource([WhatsNewFixtures.document("0.66.0", entries: 2, origin: .feed)], readsNetwork: true)
        let bundled = StubWhatsNewSource([WhatsNewFixtures.document("0.66.0", entries: 1)])
        let updated = center("0.66.0", defaults, sources: [feed, bundled])
        await updated.load().value
        #expect(feed.asked == [WhatsNewVersion("0.65.0")])
        #expect(bundled.asked == [nil])
        #expect(updated.unseen.first?.origin == .bundled)
        #expect(updated.unseen.first?.entries.count == 1)
    }

    @Test func aBuildWithoutAnOrderableVersionShowsNothing() async {
        let defaults = WhatsNewFixtures.defaults()
        let dev = center("0", defaults)
        await dev.load().value
        #expect(dev.unseen.isEmpty)
        #expect(dev.open().isEmpty)
    }
}
