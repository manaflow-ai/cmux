#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Testing
import UIKit
import WebKit
@testable import CmuxMobileWorkspaces

/// The overview's previews of panes (Leo, 2026-11-23: "we need previews of panes on our computer to
/// not be ... busted"). `ws-cmux` (mock) lists t-claude (agent), t-zsh (terminal), t-docs (browser).
@MainActor @Suite(.serialized) struct TabCardPreviewTests {
    /// A browser page left by a swipe or a tap keeps its picture on its card. The picture was
    /// taken only when the grid opened on the page itself, so a page left for another tab showed the
    /// blank globe in the grid (an off-screen web view takes no snapshot), or an older visit's page.
    @Test func aBrowserLeftForAnotherTabKeepsItsPictureOnItsCard() async throws {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: AgentSessionDirectory(), clock: GridTestClock())
        source.paneFilter = PaneFilterSetting(defaults: nil)
        source.paneFilter.showsBrowsers = true
        source.opened()
        let docs = try #require(source.workspace?.tabs.first { $0.id == "t-docs" })
        let page = source.localBrowser(docs)
        // On screen, as the tab's page is in the app.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        page.webView.frame = window.bounds
        window.addSubview(page.webView)
        window.isHidden = false
        defer { window.isHidden = true }
        page.webView.loadHTMLString("<!doctype html><title>docs</title><body style='background:#e33'>docs", baseURL: nil)
        // test: WebKit's load has no completion to await here; bounded by the clock, not a count of
        // sleeps: a loaded simulator host took past 20 s to start WebKit's content process.
        let loadDeadline = ContinuousClock.now + .seconds(60)
        while page.title != "docs", ContinuousClock.now < loadDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(page.title == "docs", "WebKit loaded the page")
        source.activate("t-docs")
        #expect(page.snapshot == nil)

        let left = ContinuousClock.now
        source.activate("t-claude")
        let shotDeadline = left + .seconds(30)
        while page.snapshot == nil, ContinuousClock.now < shotDeadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(page.snapshot != nil, "the card of a page left for another tab shows that page")
        let ms = (ContinuousClock.now - left).components
        let line = "PREVIEW_TIME_TO_CORRECT browser-left-for-another-tab \(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000) ms\n"
        Attachment.record(line, named: "preview-time-to-correct.txt")
    }
}
#endif
