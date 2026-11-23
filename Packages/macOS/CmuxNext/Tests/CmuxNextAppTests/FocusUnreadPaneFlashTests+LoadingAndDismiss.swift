import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextFocus
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42210, the rings and blue dots that would not go.
extension FocusUnreadPaneFlashTests {
    /// A chat still loading has no content to type into yet: its focus resolves to the pane alone
    /// (`emptyPane`), which named no tab, so the pane was never viewed. Clicking or focusing into
    /// it left the ring and the dot until the page came up. Its shown tab is the one looked at.
    @Test func focusingAPaneStillLoadingReadsItAndBlinksItsRingOut() async throws {
        let fixture = try await Self.open(unreadKind: .other("loading"))
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        fixture.content.layoutModel.focus(pane, source: .keyboard)
        try await PinnedPageTests.until({ fixture.controller.focus.state.pane == fixture.unread.id })
        guard case .emptyPane = fixture.controller.focus.state.resolved else {
            Issue.record("the loading pane resolved to \(fixture.controller.focus.state.resolved), not emptyPane")
            return
        }
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "focusing the loading pane left its ring" })
        #expect(fixture.unread.tabs.first?.showsUnread == false, "focusing the loading pane left its blue dot")
        #expect(fixture.content.layoutModel.attentionReadByEntry.contains(pane), "the loading pane's ring faded without the dismiss flash")
    }

    /// Dismiss (the sidebar's Dismiss Highlight) reads the workspace as classic's dismiss did: the
    /// ring blinks out and the dot goes from the tab, the row and the Dock, not only the ring.
    @Test func dismissClearsTheDotEverywhereAndBlinksTheRingOut() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        let workspace = try #require(fixture.services.machines.local.store.workspaces.first)
        fixture.services.notifications.dismissHighlight(workspace)
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "Dismiss left the ring" })
        #expect(fixture.unread.tabs.first?.showsUnread == false, "Dismiss left the tab's blue dot")
        let workspaceShowsUnread = workspace.screens.flatMap(\.panes).flatMap(\.tabs).contains { $0.showsUnread }
        #expect(!workspaceShowsUnread, "Dismiss left the workspace's dot")
        #expect(fixture.content.layoutModel.attentionReadByEntry.contains(pane), "Dismiss faded the ring without the dismiss flash")
    }
}
