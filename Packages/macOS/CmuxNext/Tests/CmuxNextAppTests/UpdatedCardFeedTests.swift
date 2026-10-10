import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSidebar
@testable import CmuxNextUpdater
import Foundation
import Testing

/// The "cmux Updated!" card's App side (cx-7py7): the feed fills the card
/// after an update and holds the tip back meanwhile; the rows run the same
/// actions as the palette (`updates.whatsNew`, `app.shareCmux`); the x
/// marks this version seen.
@MainActor @Suite(.serialized) struct UpdatedCardFeedTests {
    private func updater(updatedFrom previous: String?) async -> UpdaterService {
        let defaults = UserDefaults(suiteName: "updated-card-\(UUID().uuidString)")!  // crash-allow: test suite name
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly", shortVersion: "0.66.0", build: "100",
                                           minimumSystemVersion: nil, infoFeedURL: nil, hasPublicKey: false)
        if let previous { defaults.set(previous, forKey: WhatsNewSeenStore.lastSeenKey) }
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
        await updater.whatsNew.load().value
        updater.debugShowTip(TipCatalog.all.first?.id)
        return updater
    }

    @Test func theCardShowsAfterAnUpdateAndTheTipWaits() async throws {
        let updated = await updater(updatedFrom: "0.65.0")
        let card = try #require(SidebarCardFeed.updatedCard(updated))
        #expect(card.title == "cmux Updated!")
        #expect(card.whatsNewTitle == "See What's New")
        #expect(card.shareTitle == "Share cmux")
        #expect(SidebarCardFeed.noticeCard(updated, registry: nil) == nil, "the tip waits for the Updated card")
        updated.whatsNew.dismissUpdated()
        #expect(SidebarCardFeed.updatedCard(updated) == nil)
        #expect(SidebarCardFeed.noticeCard(updated, registry: nil) != nil)
    }

    /// Lawrence 2026-10-09: a check's result is the shared notice card (not
    /// a plain stack card) and takes the slot from the Updated card and the tip.
    @Test func aCheckResultIsTheNoticeCard() async throws {
        let updated = await updater(updatedFrom: "0.65.0")
        updated.send(.checkRequested)
        updated.debugIndicatorPhase = .note(.upToDate)
        let notice = try #require(SidebarCardFeed.noticeCard(updated, registry: nil))
        #expect(notice.id == SidebarCardFeed.updateCardID && notice.symbol == "checkmark.circle")
        #expect(notice.title == "cmux Is Up to Date" && notice.detail == "Version 0.66.0 (100), checked just now")
        #expect(notice.dismissLabel != nil && notice.actions.isEmpty)
        #expect(SidebarCardFeed.updatedCard(updated) == nil, "one card at a time")
        #expect(!SidebarCardFeed.cards(updated).contains { $0.id == SidebarCardFeed.updateCardID }, "never a plain stack card")
        SidebarCardFeed.dismissNotice(SidebarCardFeed.updateCardID, updater: updated)
        #expect(SidebarCardFeed.noticeCard(updated, registry: nil)?.id != SidebarCardFeed.updateCardID)
    }

    @Test func aFirstInstallShowsNoCard() async {
        let fresh = await updater(updatedFrom: nil)
        #expect(SidebarCardFeed.updatedCard(fresh) == nil)
    }

    @Test func theRowsRunThePaletteActionsAndTheXMarksSeen() async {
        let updated = await updater(updatedFrom: "0.65.0")
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var ran: [String] = []
        let whatsNewBound = registry.bind("updates.whatsNew", run: { _ in ran.append("updates.whatsNew") })
        let shareBound = registry.bind("app.shareCmux", run: { _ in ran.append("app.shareCmux") })
        #expect(whatsNewBound && shareBound)
        SidebarCardFeed.route(.openWhatsNew, registry: registry, updater: updated)
        SidebarCardFeed.route(.shareCmux, registry: registry, updater: updated)
        #expect(ran == ["updates.whatsNew", "app.shareCmux"])
        SidebarCardFeed.route(.dismissUpdated, registry: registry, updater: updated)
        #expect(!updated.whatsNew.showsUpdatedCard)
    }
}
