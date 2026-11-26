#if os(iOS) && DEBUG
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobileWhatsNewReplayTests {
    private var pages: [MobileWhatsNewPage] {
        [
            MobileWhatsNewPage(id: "same-id", releaseLabel: nil, title: "Announcement", body: .features([]), isAnnouncement: true),
            MobileWhatsNewPage(id: "same-id", releaseLabel: nil, title: "Update", body: .features([]), isAnnouncement: false),
            MobileWhatsNewPage(id: "older", releaseLabel: nil, title: "Older update", body: .features([]), isAnnouncement: false)
        ]
    }

    @Test func rangeIncludesBothEndpointsAndIntermediatePages() throws {
        let replay = try #require(MobileWhatsNewReplay(pages: pages, firstID: "announcement:same-id", lastID: "entry:older"))
        #expect(replay.pages.map(\.listID) == pages.map(\.listID))
    }

    @Test func reversedEndpointsKeepCatalogOrder() throws {
        let replay = try #require(MobileWhatsNewReplay(pages: pages, firstID: "entry:older", lastID: "entry:same-id"))
        #expect(replay.pages.map(\.listID) == ["entry:same-id", "entry:older"])
    }

    @Test func onePageUsesNamespacedIdentity() throws {
        let replay = try #require(MobileWhatsNewReplay(pages: pages, firstID: "entry:same-id", lastID: "entry:same-id"))
        #expect(replay.pages.map(\.title) == ["Update"])
    }

    @Test func missingOrEmptyCatalogDoesNotPresent() {
        #expect(MobileWhatsNewReplay(pages: [], firstID: "", lastID: "") == nil)
        #expect(MobileWhatsNewReplay(pages: pages, firstID: "removed", lastID: "entry:older") == nil)
    }

    @Test func replayDoesNotAcknowledgeUpdates() throws {
        let suite = "MobileWhatsNewReplayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = MobileWhatsNewCenter(apiBaseURL: "https://cmux.test", buildType: .beta, defaults: defaults)
        let before = center.unseenPages.map(\.listID)
        let firstID = try #require(before.first)
        let lastID = try #require(before.last)
        let replay = try #require(MobileWhatsNewReplay(
            pages: center.archivePages,
            firstID: firstID,
            lastID: lastID
        ))
        #expect(!replay.pages.isEmpty)
        #expect(center.unseenPages.map(\.listID) == before)
        #expect(defaults.object(forKey: MobileWhatsNewCenter.markerKey) == nil)
        #expect(defaults.object(forKey: MobileWhatsNewCenter.acknowledgedAnnouncementsKey) == nil)
    }
}
#endif
