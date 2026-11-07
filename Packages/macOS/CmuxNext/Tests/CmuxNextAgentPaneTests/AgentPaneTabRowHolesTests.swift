#if DEBUG
import AppKit
import CmuxNextDesign
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

        // The tabs (left of the chat's tools), the window's top rim over the tools, and the pane's
        // toolbar (right of them) show through.
        #expect(holes(page, in: view) == [
            CGRect(x: 0, y: 0, width: room - span, height: 36),
            CGRect(x: room - span, y: 0, width: span, height: 1),
            CGRect(x: 740, y: 0, width: 60, height: 36),
        ])
    }

    /// Leo (2026-11-03), on a chat alone in its pane: "isn't it kinda arbitrary anyway if you literally
    /// only have one tab there?" The pane hides that tab, so the page shows through the row's leading
    /// end too: only the pane's toolbar stays uncovered.
    @Test func aLoneTabLeavesOnlyTheToolbarUncovered() async throws {
        let (view, page) = try await chromiumChat()
        view.model.tabRow.report(width: 120)
        view.model.tabRow.tabsShown = false // PaneTabRowSharing.setTabRowTabs, as the pane calls it before the offer
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        #expect(holes(page, in: view) == [
            CGRect(x: 0, y: 0, width: 740, height: 1),
            CGRect(x: 740, y: 0, width: 60, height: 36),
        ])

        // A second tab brings the strip back, and its hole with it.
        view.model.tabRow.tabsShown = true
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        #expect(holes(page, in: view).count == 3)
    }

    /// Leo (2026-11-03, the nightly): "latest nightly still not fixed yet?" / "i mean the rectangle near the
    /// buttons". Alone in its pane a Chromium chat paints its own surface (`appearance.surfaces.agentPane`)
    /// across the whole row, but its page window leaves the pane's toolbar a hole, where the pane's own shade
    /// showed: a block of another color beside the tools (#33261). The toolbar hole paints the page's surface,
    /// so nothing in the row differs from the surface around it; a row the page leaves clear paints nothing.
    @Test func aLoneChromiumChatsToolbarHolePaintsThePagesSurface() {
        let chat = ThemeRGB(hex: 0x282938)
        #expect(AgentPaneTabRow.holeFill(chromium: true, shares: true, tabsShown: false, page: chat) == chat.cgColor)
        // Tabs shown: the page leaves the row clear, so the hole shows the same pane the page does.
        #expect(AgentPaneTabRow.holeFill(chromium: true, shares: true, tabsShown: true, page: chat) == nil)
        // WebKit: the page is under the toolbar and already paints there.
        #expect(AgentPaneTabRow.holeFill(chromium: false, shares: true, tabsShown: false, page: chat) == nil)
        // Out of the row, or a clear page (glass): nothing.
        #expect(AgentPaneTabRow.holeFill(chromium: true, shares: false, tabsShown: false, page: chat) == nil)
        #expect(AgentPaneTabRow.holeFill(chromium: true, shares: true, tabsShown: false, page: chat.withAlpha(0)) == nil)
    }

    /// The chat hands its pane the fill with each offer, in its own theme scope, and drops it with the row.
    @Test func aLoneChromiumChatHandsThePaneItsSurfaceForTheToolbar() async throws {
        let (view, _) = try await chromiumChat()
        view.model.tabRow.report(width: 120)
        view.model.tabRow.tabsShown = false
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        let surface = view.performWithTheme { AgentPaneTheme.pageBackground(view.themeTokens, surface: .agentPane) }
        #expect(view.model.tabRow.holeFill == (surface.alpha > 0 ? surface.cgColor : nil))

        view.model.tabRow.tabsShown = true
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        #expect(view.model.tabRow.holeFill == nil)
        view.model.tabRow.tabsShown = false
        AgentPaneTabRow.offer(points: 0, trailingInset: 0, to: view)
        #expect(view.model.tabRow.holeFill == nil)
    }

    /// A shared page host on WebKit: the page is under the toolbar and already paints there, so a translucent
    /// surface would darken twice under a fill (review of #33407).
    @Test func aLoneWebKitChatPaintsNoToolbarHole() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true, testRoot: true, chromium: nil))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(view.chromiumPage == nil)
        view.model.tabRow.report(width: 120)
        view.model.tabRow.tabsShown = false
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        #expect(view.model.tabRow.holeFill == nil)
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
        let span = min(tools, room / 2)
        #expect(holes(page, in: view) == [
            CGRect(x: 0, y: 0, width: room - span, height: 36),
            CGRect(x: room - span, y: 0, width: span, height: 1),
            CGRect(x: 940, y: 0, width: 60, height: 36),
        ])
    }

    /// Leo (2026-11-03): "there is clearly a rectangle that is just covering up the glass at the rim of
    /// the top of the app". Where the row meets the window's top edge, the page window over the
    /// chat's tools drew a flat gray 1 pt line (rgb 69,71,70 in every theme) in place of the window's
    /// lit rim, which the tabs' hole beside it showed: the rim stopped where the tools began. The page
    /// leaves the row's top point uncovered across the tools too, so the rim runs the whole width, and
    /// the holes never overlap (the fork masks with them even-odd: an overlap would cover it again).
    @Test func theWindowsTopRimStaysUncoveredAcrossTheTools() async throws {
        let (view, page) = try await chromiumChat()
        view.model.tabRow.report(width: 120)
        for (tabs, inset) in [(true, CGFloat(60)), (false, 60), (true, 0), (false, 0)] {
            view.model.tabRow.tabsShown = tabs
            AgentPaneTabRow.offer(points: 36, trailingInset: inset, to: view)
            let rects = holes(page, in: view)
            // Every point of the row's top edge is in exactly one hole.
            for x in stride(from: CGFloat(0.5), to: 800, by: 1) {
                let hits = rects.filter { $0.contains(CGPoint(x: x, y: 0.5)) }.count
                #expect(hits == 1, "x \(x), tabs \(tabs), inset \(inset): \(rects)")
            }
            // Below the rim the chat's tools stay the page's, so they still take clicks.
            let tools = try #require(view.model.tabRow.sharedWidth(zoom: view.webView.pageZoom))
            let room = 800 - inset
            let toolsMid = CGPoint(x: room - min(tools, room / 2) / 2, y: 18)
            #expect(!rects.contains { $0.contains(toolsMid) })
        }
    }
}
#endif
