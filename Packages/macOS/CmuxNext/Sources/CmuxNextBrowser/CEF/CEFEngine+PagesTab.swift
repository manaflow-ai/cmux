import CmuxNextDesign
public import CmuxNextWakeups
import Foundation

/// Why ``CEFEngine/makePagesTab(_:)`` made no page tab.
public nonisolated enum CEFPagesTabError: Error {
    /// The engine made a tab that is not a CEF tab.
    case notChromium
}

/// A cmux page's own Chromium tab (`ChromiumPageHost`): every page shares the pages profile (``beginPagesProfile()``)
/// and has a pane of its own, so it is never a tab of a browser pane's Chromium window.
extension CEFEngine {
    /// The configuration of a new cmux page tab: the pages profile and a pane of its own. `chatOpen` (the agent chat
    /// open the page shows) gets the stages of the window that pane gets: its create, created and first contentful
    /// paint, until that paint or until the window's host leaves the routing table. A window taken from the spare
    /// was made before: only its paint is a stage.
    ///
    /// - Parameter chatOpen: The open the page shows; nil for any other page.
    /// - Returns: The tab's configuration, for ``makePagesTab(_:)``.
    public func pagesTabConfiguration(chatOpen: ChatOpenStages?) -> BrowserTabConfiguration {
        let pane = BrowserPaneID(rawValue: "cmux-page-" + UUID().uuidString)
        if let chatOpen { CEFRuntime.shared.chatOpens[pane.rawValue] = chatOpen }
        return BrowserTabConfiguration(profile: beginPagesProfile(), pane: pane, origin: .user)
    }

    /// Makes the page tab `configuration` describes (``pagesTabConfiguration(chatOpen:)``), themed as an internal page.
    ///
    /// - Parameter configuration: The page tab's configuration.
    /// - Returns: The tab.
    /// - Throws: ``CEFPagesTabError`` when the tab is not a CEF tab, or the engine's error when Chromium cannot start.
    public func makePagesTab(_ configuration: BrowserTabConfiguration) async throws -> CEFTab {
        let made = try await makeTab(configuration)
        guard let tab = made as? CEFTab else {
            made.close()
            throw CEFPagesTabError.notChromium
        }
        tab.pageThemeSurface = .internalPage
        return tab
    }
}

extension CEFRuntime {
    /// Writes `stage` for the chat open whose page's window is `pane`'s (``CEFEngine/pagesTabConfiguration(chatOpen:)``):
    /// one dictionary read per window step when none is. The first contentful paint is the last.
    func chatStage(_ stage: ChatOpenStage, pane: String) {
        guard let chatOpen = chatOpens[pane] else { return }
        if stage == .firstContentfulPaint { chatOpens[pane] = nil }
        chatOpen.mark(stage)
    }
}
