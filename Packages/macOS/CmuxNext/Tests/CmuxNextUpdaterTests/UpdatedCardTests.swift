import Foundation
import Testing
@testable import CmuxNextUpdater

/// The "cmux Updated!" card (cx-7py7): it shows once after the installed
/// version moves past the last seen one, never on a first install, and it
/// shares What's New's one seen state: the card's x, the card's What's New
/// row, the palette and the sidebar item all clear the card and the dot.
@MainActor
@Suite struct UpdatedCardTests {
    let documents = ["0.65.0", "0.66.0", "0.67.0"].map { WhatsNewFixtures.document($0) }

    private func center(_ version: String, _ defaults: UserDefaults, sources: [any WhatsNewSource]? = nil) async -> WhatsNewCenter {
        let center = WhatsNewCenter(currentVersion: version, defaults: defaults, sources: sources ?? [StubWhatsNewSource(documents)])
        await center.load().value
        return center
    }

    @Test func aFirstInstallShowsNoCard() async {
        let fresh = await center("0.66.0", WhatsNewFixtures.defaults())
        #expect(!fresh.showsUpdatedCard)
    }

    @Test func aVersionChangeShowsTheCardOnceAndTheDismissalSurvivesARelaunch() async {
        let defaults = WhatsNewFixtures.defaults()
        _ = await center("0.65.0", defaults)
        let updated = await center("0.66.0", defaults)
        #expect(updated.showsUpdatedCard)
        updated.dismissUpdated()
        #expect(!updated.showsUpdatedCard)
        #expect(!updated.showsItem, "one seen state: the x also clears the What's New dot")
        let relaunched = await center("0.66.0", defaults)
        #expect(!relaunched.showsUpdatedCard, "dismissed for this version")
    }

    @Test func theDismissalIsPerVersion() async {
        let defaults = WhatsNewFixtures.defaults()
        _ = await center("0.65.0", defaults)
        await center("0.66.0", defaults).dismissUpdated()
        let next = await center("0.67.0", defaults)
        #expect(next.showsUpdatedCard, "the next version shows the card again")
    }

    @Test func openingWhatsNewClearsTheCard() async {
        let defaults = WhatsNewFixtures.defaults()
        _ = await center("0.65.0", defaults)
        let updated = await center("0.66.0", defaults)
        updated.open()
        #expect(!updated.showsUpdatedCard)
        #expect(!(await center("0.66.0", defaults)).showsUpdatedCard)
    }

    @Test func anUpdateWithoutNotesStillShowsTheCard() async {
        let defaults = WhatsNewFixtures.defaults()
        _ = await center("0.65.0", defaults, sources: [])
        let updated = await center("0.66.0", defaults, sources: [])
        #expect(updated.showsUpdatedCard)
        #expect(!updated.showsItem)
    }

    @Test func aRollbackOrTheSettingOffShowsNoCard() async {
        let defaults = WhatsNewFixtures.defaults()
        _ = await center("0.66.0", defaults)
        #expect(!(await center("0.65.0", defaults)).showsUpdatedCard)
        let other = WhatsNewFixtures.defaults()
        _ = await center("0.65.0", other)
        let updated = await center("0.66.0", other)
        updated.isItemEnabled = false
        #expect(!updated.showsUpdatedCard)
    }

    /// Chief 2026-10-08: nightly builds update several times a day, so only
    /// stable and RC version changes show the card. The What's New item
    /// keeps its own rule (notes the user has not seen).
    @Test func onlyStableAndRCUpdatesShowTheCard() async {
        let nightly = WhatsNewFixtures.defaults()
        _ = await center("0.66.0-nightly.10", nightly, sources: [])
        #expect(!(await center("0.66.0-nightly.11", nightly, sources: [])).showsUpdatedCard, "nightly to nightly")
        let toNightly = WhatsNewFixtures.defaults()
        _ = await center("0.65.0", toNightly, sources: [])
        #expect(!(await center("0.66.0-nightly.3", toNightly, sources: [])).showsUpdatedCard, "stable to nightly")
        let rc = WhatsNewFixtures.defaults()
        _ = await center("0.65.0", rc, sources: [])
        #expect((await center("0.66.0-rc.1", rc, sources: [])).showsUpdatedCard, "an RC shows the card")
        let stable = WhatsNewFixtures.defaults()
        _ = await center("0.66.0-nightly.12", stable, sources: [])
        #expect((await center("0.66.0", stable, sources: [])).showsUpdatedCard, "nightly to stable shows the card")
    }

    /// DEV/NIGHTLY proof (`debug.updater {action: "updated", previous}`):
    /// a fake previous version shows the card on this launch.
    @Test func aFakePreviousVersionShowsTheCard() async {
        let fresh = await center("0.66.0", WhatsNewFixtures.defaults())
        #expect(fresh.debugPretendUpdated(from: "0.65.0"))
        #expect(fresh.showsUpdatedCard)
        #expect(fresh.unseen.map(\.version) == ["0.66.0"])
        #expect(!fresh.debugPretendUpdated(from: "0.67.0"), "a newer previous version is refused")
    }
}
