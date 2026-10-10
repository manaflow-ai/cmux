import Foundation
import os

/// An agent-driven CEF tab never stays on a page `AgentURLPolicy` refuses,
/// whatever brought it there: a redirect, an opener, a history step, a
/// restored entry, or a person's page an agent just took
/// (plans/cmux-next/passwords.md, section 2). Chromium already blocks web
/// pages from navigating to its own pages; this is the last line. Events
/// reach the tab on a later main-queue pass than the CEF callback, so the
/// load here does not re-enter Chromium.
enum CEFAgentURLGuard {
    /// Bit 2 of `cmux_shim_set_navigation_guard`: the shim cancels a main-frame
    /// navigation to a refused page before it commits (OnBeforeBrowse). The
    /// after-commit `leave` below stays as the last line.
    static let shimAgentBit: Int32 = 4

    static func shimGuardMode(_ store: BrowserNavigationGuard, agentDriven: Bool) -> Int32 {
        store.rawValue | (agentDriven ? shimAgentBit : 0)
    }

    /// Applied when the browser attaches (before any pending load) and when
    /// the tab becomes agent-driven.
    static func applyShimGuard(_ tab: CEFTab) {
        guard let browser = tab.browserID else { return }
        let mode = shimGuardMode(tab.navigationGuard, agentDriven: tab.isAgentDriven)
        if mode != 0 { tab.runtime.shim?.setNavigationGuard(browser, mode) }
    }

    /// The URL a new browser is created with. Its first navigation starts
    /// before the guard can be set, so an agent-driven tab never starts on
    /// a refused page.
    static func creationURL(_ pending: URL?, agentDriven: Bool) -> String {
        guard let pending else { return BrowserNewTabPage.blankURL }
        return agentDriven && AgentURLPolicy.refuses(pending) ? BrowserNewTabPage.blankURL : pending.absoluteString
    }

    static func check(_ tab: CEFTab, after event: CEFShimEvent) {
        switch event {
        case .loadStart(_, let url), .address(_, let url): leave(tab, URL(string: url))
        default: break
        }
    }

    static func leave(_ tab: CEFTab, _ url: URL?) {
        guard tab.isAgentDriven, let url, AgentURLPolicy.refuses(url), let blank = AgentURLPolicy.replacementURL else { return }
        // No URL in the line: it may name a profile page.
        tab.runtime.logger.notice("agent-driven browser left a Chromium page agents may not use")
        tab.stop()
        tab.load(blank)
    }
}
