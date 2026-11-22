@testable import CmuxNextApp
import CmuxNextSidebar
import CmuxNextUpdater
import Foundation
import Testing

/// WHATS-NEW-AFTER-UPDATE W1: the What's New page is a top page; its
/// client-only sidebar item shows after an update until opened (with an
/// unread dot) and while the window shows the page; feed documents run only
/// allow-listed try-it actions.
@MainActor
struct WhatsNewTopPageTests {
    private func center(updated: Bool) async -> WhatsNewCenter {
        let defaults = UserDefaults(suiteName: "whats-new-app-\(UUID().uuidString)")!  // crash-allow: test suite name
        let document = WhatsNewDocument(version: "0.66.0", channel: .stable, date: "2026-10-07", headline: "H", entries: [
            WhatsNewDocument.Entry(id: "a", category: .new, title: "T", summary: "S.", tryIt: WhatsNewDocument.TryIt(action: "home.show")),
        ])
        if updated { await WhatsNewCenter(currentVersion: "0.65.0", defaults: defaults, sources: []).load().value }
        let center = WhatsNewCenter(currentVersion: "0.66.0", defaults: defaults, sources: [OneDocumentSource(document: document)])
        await center.load().value
        return center
    }

    @Test func thePageRoutePersistsLikeOtherTopPages() {
        #expect(WhatsNewPage.route.rawValue == "page:whats-new")
        #expect(TopPageRoute(rawValue: "page:whats-new") == WhatsNewPage.route)
        #expect(WhatsNewPage.sidebarItemID.isTransient)
    }

    @Test func theItemShowsWithADotAfterAnUpdateUntilOpened() async throws {
        let center = await center(updated: true)
        let item = try #require(WhatsNewPage.sidebarItem(center: center, shownPage: nil))
        #expect(item.info.unreadDot)
        center.open()
        #expect(WhatsNewPage.sidebarItem(center: center, shownPage: nil) == nil)
        // While the window shows the page, the item stays (no dot) as its selection.
        let shown = try #require(WhatsNewPage.sidebarItem(center: center, shownPage: WhatsNewPage.route))
        #expect(!shown.info.unreadDot)
        #expect(SidebarNavigation.selectedItem(page: WhatsNewPage.route, workspace: nil, layout: .defaults)
            == .topItem(WhatsNewPage.sidebarItemID))
    }

    @Test func aFreshInstallOrTheSettingOffShowsNoItem() async {
        let fresh = await center(updated: false)
        #expect(WhatsNewPage.sidebarItem(center: fresh, shownPage: nil) == nil)
        let updated = await center(updated: true)
        updated.isItemEnabled = false
        #expect(WhatsNewPage.sidebarItem(center: updated, shownPage: nil) == nil)
    }

    @Test func feedDocumentsRunOnlyAllowListedActions() {
        #expect(WhatsNewPage.canTry(WhatsNewDocument.TryIt(action: "anything.at.all"), origin: .bundled))
        #expect(WhatsNewPage.canTry(WhatsNewDocument.TryIt(deeplink: "cmux://settings"), origin: .bundled))
        #expect(WhatsNewPage.canTry(WhatsNewDocument.TryIt(action: "palette.checkForUpdates"), origin: .feed))
        #expect(!WhatsNewPage.canTry(WhatsNewDocument.TryIt(action: "quitEndEverything"), origin: .feed))
        #expect(!WhatsNewPage.canTry(WhatsNewDocument.TryIt(deeplink: "cmux://settings"), origin: .feed))
    }
}

nonisolated struct OneDocumentSource: WhatsNewSource {
    let document: WhatsNewDocument
    func documents(after: WhatsNewVersion?, through: WhatsNewVersion) async -> [WhatsNewDocument] { [document] }
}
