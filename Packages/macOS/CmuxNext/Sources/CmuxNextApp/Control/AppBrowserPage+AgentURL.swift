import CmuxNextBrowser
import CmuxNextControl
import Foundation

/// Agent page operations never load, show or script a page `AgentURLPolicy`
/// refuses (plans/cmux-next/passwords.md, section 2). The CEF tab also
/// leaves such a page if a redirect or a restored entry commits it anyway
/// (`CEFTab.leaveRefusedPageIfAgentDriven`).
extension AppBrowserPage {
    static func agentURLRefusal(_ operation: BrowserPageOperation, target: URL?, page: any BrowserTab) -> ControlError? {
        let refused: Bool
        switch operation {
        case .state: refused = false
        case .navigate: refused = target.map(AgentURLPolicy.refuses) ?? false
        case .back: refused = historyStepRefused(page, offset: -1)
        case .forward: refused = historyStepRefused(page, offset: 1)
        case .reload, .evaluate: refused = showsRefusedPage(page)
        }
        guard refused else { return nil }
        return ControlError(
            code: "forbidden",
            message: "Agents cannot open or script Chromium's own pages (chrome://, chrome-extension://, devtools://, chrome-untrusted://)"
        )
    }

    static func showsRefusedPage(_ page: any BrowserTab) -> Bool {
        if let url = page.state.url, AgentURLPolicy.refuses(url) { return true }
        guard let list = (page as? any BrowserBackForwardListing)?.navigationList(),
              list.entries.indices.contains(list.current), let url = list.entries[list.current].url else { return false }
        return AgentURLPolicy.refuses(url)
    }

    /// Without Chromium's list the target is unknown: a Chromium tab refuses;
    /// WebKit cannot load these pages at all.
    static func historyStepRefused(_ page: any BrowserTab, offset: Int) -> Bool {
        guard let list = (page as? any BrowserBackForwardListing)?.navigationList() else { return page.engineKind == .cef }
        let index = list.current + offset
        guard list.entries.indices.contains(index) else { return false }
        guard let url = list.entries[index].url else { return page.engineKind == .cef }
        return AgentURLPolicy.refuses(url)
    }
}
