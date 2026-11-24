#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-11-24: "man it's unsatisfying for the buttons to track the dragging of the pane split dividers so poorly. it
/// lags, it doesn't follow in lockstep." Through a resize drag the pane draws a Chromium chat's tools itself
/// (`AgentPaneTabRow+StandIn`), in a band over the page's own, and gives the row back once the page drew at its final size.
@Suite(.serialized)
@MainActor
struct AgentPaneTabRowStandInTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private let tools = [PaneTabRowTool(id: "terminal", symbol: "terminal", label: "Terminal"),
                         PaneTabRowTool(id: "chat-menu", symbol: "ellipsis", label: "Chat")]

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

    /// The page window's holes, in the chat view's coordinates from its top-left corner.
    private func holes(_ page: FakeChromiumPage, in view: AgentPaneView) -> [CGRect] {
        page.occlusionRects.map { rect -> CGRect in
            let local = view.convert(rect, from: page.contentView)
            let top = view.isFlipped ? local.minY - view.bounds.minY : view.bounds.maxY - local.maxY
            return CGRect(x: local.minX, y: top, width: local.width, height: local.height).integral
        }
        .sorted { $0.minX < $1.minX }
    }

    /// The band, back from the chat view's coordinates to the row's (top-left origin).
    private func band(_ view: AgentPaneView) throws -> CGRect {
        let frame = try #require(view.model.tabRow.standIn?.frame)
        return CGRect(x: frame.minX, y: view.bounds.maxY - frame.maxY, width: frame.width, height: frame.height).integral
    }

    private func resize(_ view: AgentPaneView, width: CGFloat) {
        view.setFrameSize(NSSize(width: width, height: 600))
        view.applyNativeRects() // a drag frame lays the chat out before its pane offers the row again
    }

    @Test func aChromiumChatIsOfferedTheStandInOnlyWithNativeRowToolsOff() async throws {
        let (view, _) = try await chromiumChat()
        view.model.tabRow.report(width: 120)
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        #expect(view.model.tabRow.event.value["standInRowTools"]?.boolValue == !ChromeTunables.nativeRowTools.value)
        AgentPaneTabRow.offer(points: 0, trailingInset: 0, to: view)
        #expect(view.model.tabRow.event.value["standInRowTools"]?.boolValue == false, "a page with no row publishes nothing")
        #expect(AgentPageEvent.tabRow(height: 36, trailingInset: 60, nativeRowTools: false).value["standInRowTools"]?.boolValue == false)
    }

    @Test func publishedToolsFeedTheStandInNotTheNativeRow() async {
        let model = AgentPaneModel(host: NoHost())
        guard !model.tabRow.nativeToolsEnabled else { return }
        _ = await model.respond(to: .tabRowToolsSet(tools))
        #expect(model.tabRow.standInTools == tools)
        #expect(model.tabRowTools.isEmpty, "the stand-in's tools showed in the pane's toolbar")
    }

    @Test func theBandCoversEveryXTheToolsTookAndTheRowComesBackAfterThePageDrew() async throws {
        let (view, page) = try await chromiumChat()
        let row = view.model.tabRow
        row.report(width: 120)
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        guard row.offeredStandIn == true else { return } // native row tools on: the row draws them all the time
        let span = try #require(row.sharedWidth(zoom: view.webView.pageZoom))
        let normal = holes(page, in: view)
        row.setStandInTools(tools)
        #expect(row.standIn == nil, "a band showed with no drag")

        view.paneResizeGestureDidChange(active: true)
        #expect(row.standingIn)
        view.applyNativeRects()
        let start = 740 - span
        #expect(try band(view) == CGRect(x: start, y: 0, width: span, height: 36).integral)
        #expect(row.standIn?.rim == PaneTabRowRim.height)
        #expect(row.standIn?.tools == tools)

        // Grown: the page's tools may still be where they were, so the band keeps that x.
        resize(view, width: 900)
        #expect(try band(view) == CGRect(x: start, y: 0, width: 840 - start, height: 36).integral)
        // The tabs end where the band begins, the band and the toolbar are one full-height hole: nothing overlaps.
        #expect(holes(page, in: view) == [
            CGRect(x: 0, y: 0, width: start, height: 36).integral,
            CGRect(x: start, y: 0, width: 900 - start, height: 36).integral,
        ])
        // Shrunk past the start: the band follows the tools left, and keeps the x they took to the drag's end.
        resize(view, width: 700)
        let left = 640 - span
        #expect(try band(view) == CGRect(x: left, y: 0, width: span, height: 36).integral)
        resize(view, width: 760)
        #expect(try band(view).minX == floor(left))

        var drawn: (() -> Void)?
        row.endStandIn { drawn = $0 }
        view.applyNativeRects()
        #expect(row.standIn != nil, "the band went before the page drew at its final size")
        try #require(drawn)()
        view.applyNativeRects()
        #expect(row.standIn == nil)
        resize(view, width: 800)
        #expect(holes(page, in: view) == normal)
    }

    @Test func aDragBegunBeforeThePageDrewKeepsTheBand() async throws {
        let (view, _) = try await chromiumChat()
        let row = view.model.tabRow
        row.report(width: 120)
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        guard row.offeredStandIn == true else { return }
        row.setStandInTools(tools)
        view.paneResizeGestureDidChange(active: true)
        var drawn: (() -> Void)?
        row.endStandIn { drawn = $0 }
        view.paneResizeGestureDidChange(active: true)
        try #require(drawn)()
        view.applyNativeRects()
        #expect(row.standIn != nil, "an earlier drag's paint ended the drag under way")
    }

    @Test func noBandWithoutPublishedTools() async throws {
        let (view, page) = try await chromiumChat()
        let row = view.model.tabRow
        row.report(width: 120)
        AgentPaneTabRow.offer(points: 36, trailingInset: 60, to: view)
        let normal = holes(page, in: view)
        view.paneResizeGestureDidChange(active: true)
        view.applyNativeRects()
        #expect(row.standIn == nil)
        #expect(holes(page, in: view) == normal, "the page lost its tools' area with nothing drawn over it")
    }
}
#endif
