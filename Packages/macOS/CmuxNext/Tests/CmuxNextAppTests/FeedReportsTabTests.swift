import AppKit
@testable import CmuxNextFeed
import CmuxNextTestSupport
import Foundation
import SwiftUI
import Testing

/// The reports basket is a tab of the Feed inbox, on by default (Leo-ask ask-b7707cc5b2), next to
/// GitHub and Feed: it shows agent reports that wake no model, with a reply box, and it hides the
/// item search and triage row, which belong to the items. The Feed's item list keeps no row under it.
@MainActor @Suite(.closesItsWindows) struct FeedReportsTabTests {
    private func host(_ view: some View) -> (NSWindow, NSView) {
        let size = NSSize(width: 520, height: 320)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func header(_ connection: FeedInboxFilter.Connection) -> FeedInboxHeader {
        FeedInboxHeader(filter: .constant(FeedInboxFilter(connection: connection)), hasUnread: true, canRefresh: true,
                        canAddConnection: false, markRead: {}, refresh: {}, addConnection: {}, showsReports: true)
    }

    @Test func theReportsTabHidesTheItemSearch() {
        let (feedWindow, feed) = host(header(.feed))
        defer { feedWindow.contentView = nil; feedWindow.close() }
        #expect(HomeSheetThemeTests.editableFields(in: feed).count == 1, "the Feed tab has its search field")

        let (reportsWindow, reports) = host(header(.reports))
        defer { reportsWindow.contentView = nil; reportsWindow.close() }
        #expect(HomeSheetThemeTests.editableFields(in: reports).isEmpty, "the Reports tab has no item search")
    }

    @Test func theReportsTabListsNoFeedItems() {
        let item = FeedItem(id: "fi_1", title: "Finished", body: "done", context: FeedContext(tab: "tab_1"),
                            poster: FeedPoster(kind: .agent, label: "Agent"), createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(FeedInboxFilter(connection: .feed).items(from: [item]).map(\.id) == ["fi_1"])
        #expect(FeedInboxFilter(connection: .reports).items(from: [item]).isEmpty)
    }
}
