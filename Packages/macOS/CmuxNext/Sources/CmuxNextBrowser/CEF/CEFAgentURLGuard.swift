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
