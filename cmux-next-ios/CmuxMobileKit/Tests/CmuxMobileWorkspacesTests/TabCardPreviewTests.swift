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
        // test: WebKit's load has no completion to await here; bounded.
        for _ in 0..<4000 where page.title != "docs" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(page.title == "docs")
        source.activate("t-docs")
        #expect(page.snapshot == nil)

        let left = ContinuousClock.now
        source.activate("t-claude")
        for _ in 0..<2000 where page.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(page.snapshot != nil, "the card of a page left for another tab shows that page")
        print("CMUX_PREVIEW_TIME_TO_CORRECT browser-left \(ContinuousClock.now - left)")
    }
}
#endif
