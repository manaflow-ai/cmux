#if DEBUG
import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Lawrence 2026-10-21 (msg 8412, "default behavior, show the tabs in agent chats"): with the chat's
/// tools in the tab row (`chrome.tabs.rowTools`, on by default) the pane lays the chat over its tab
/// row, and since the chat shows in Chromium by default (`agent.chromium`) the chat is a child window
/// above the whole pane: it covered the pane's native tabs and toolbar, so an agent chat showed no
/// tabs. While the chat shares the row, its Chromium page leaves the tabs and the toolbar uncovered
/// (holes in the page window), and only its own tools draw in the row.
@Suite(.serialized)
@MainActor
struct AgentPaneTabRowHolesTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func chromiumChat() async throws -> (AgentPaneView, FakeChromiumPage) {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true, testRoot: true,
                                              chromium: hosting))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while !view.debugShowsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.debugShowsChromium)
        let page = try #require(hosting.made.last)
        return (view, page)
    }

    /// The holes the page window has, back in the chat view's coordinates measured from its top-left
    /// corner. The chat view is not flipped, so y 0 of its own coordinates is its bottom: holes there
    /// cut the composer's footer row out of the page and leave the tabs covered (Lucas 2026-10-23).
    private func holes(_ page: FakeChromiumPage, in view: AgentPaneView) -> [CGRect] {
        page.occlusionRects.map { rect -> CGRect in
            let local = view.convert(rect, from: page.contentView)
            let top = view.isFlipped ? local.minY - view.bounds.minY : view.bounds.maxY - local.maxY
            return CGRect(x: local.minX, y: top, width: local.width, height: local.height).integral
        }
        .sorted { $0.minX < $1.minX }
    }

    @Test func aChromiumChatInTheTabRowLeavesTheTabsAndToolbarUncovered() async throws {
        let (view, page) = try await chromiumChat()
        view.model.tabRow.report(width: 120)
        let tools = try #require(view.model.tabRow.sharedWidth(zoom: view.webView.pageZoom))
        let room: CGFloat = 800 - 60
        let span = min(tools, room / 2)

        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)

        // The tabs (left of the chat's tools) and the pane's toolbar (right of them) show through.
        #expect(holes(page, in: view) == [
            CGRect(x: 0, y: 0, width: room - span, height: 36),
            CGRect(x: 740, y: 0, width: 60, height: 36),
        ])
    }

    @Test func aChatOutOfTheRowCoversNothing() async throws {
        let (view, page) = try await chromiumChat()
        view.model.tabRow.report(width: 120)
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        #expect(!page.occlusionRects.isEmpty)

        // The row ends (a narrow pane, the bar at the bottom, the setting off): the chat sits under
        // the tabs and needs no hole.
        AgentPaneTabRow.offer(points: 0, trailingInset: 0, to: view)
        #expect(page.occlusionRects.isEmpty)
    }

    @Test func theHolesFollowThePanesWidth() async throws {
        let (view, page) = try await chromiumChat()
        view.model.tabRow.report(width: 120)
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        view.layoutSubtreeIfNeeded()
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        let tools = try #require(view.model.tabRow.sharedWidth(zoom: view.webView.pageZoom))
        let room: CGFloat = 1000 - 60
        #expect(holes(page, in: view) == [
            CGRect(x: 0, y: 0, width: room - min(tools, room / 2), height: 36),
            CGRect(x: 940, y: 0, width: 60, height: 36),
        ])
    }
}
#endif
