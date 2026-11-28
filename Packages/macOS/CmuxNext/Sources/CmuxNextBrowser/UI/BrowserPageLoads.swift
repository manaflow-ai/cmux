import Foundation

/// What a tab's loads write while it lives, whether or not its pane shows it (Chrome's HistoryTabHelper is per tab,
/// not per toolbar): each finished visit and title into history, each finished page once to `onPageFinished`, and a
/// typed https upgrade that failed falls back to http. With one chrome per pane (#32909 step B) a toolbar only sees
/// the tab it shows, so this follows the tab itself (`BrowserChromeTabState.loads`); a chrome that shows one page
/// only has its own.
@MainActor
final class BrowserPageLoads {
    var history: (any BrowserHistoryStore)?
    var onPageFinished: ((URL) -> Void)?
    /// Each committed main-frame URL once, as soon as its document replaces the old one (before it
    /// finishes loading): the host's `browser.siteEngines` check for a page that navigated.
    var onPageCommitted: ((URL) -> Void)?
    /// A typed https upgrade in flight (Chrome's http fallback).
    var httpsFallback = HTTPSUpgradeFallback()
    private var recordedURL: URL?
    private var recordedTitle: String?
    private var finishedURL: URL?
    private var committedURL: URL?
    private weak var tab: (any BrowserTab)?
    private var observation: ObservationLoop?

    /// Follows `tab`'s loads from now on (a tab's state follows its page from the start).
    func follow(_ tab: any BrowserTab) {
        guard tab !== self.tab else { return }
        observation?.cancel()
        self.tab = tab
        observation = ObservationLoop { [weak self] in self?.observe() }
    }

    /// The tab closed: nothing more is recorded.
    func stop() {
        observation?.cancel()
        observation = nil
        tab = nil
    }

    /// The tab was restored showing `url` (relaunch, hibernation wake): its first load of that page is not a new visit.
    func markRestored(_ url: URL?) {
        guard let url, recordedURL == nil else { return }
        recordedURL = url
    }

    private func observe() {
        guard let tab else { return }
        let state = tab.state
        if let http = httpsFallback.observe(state) {
            // task-owner: one load, after this observation (never a load inside the observed read).
            Task { @MainActor [weak tab] in tab?.load(http) }
        }
        if let onPageCommitted, state.phase == .committed || state.phase == .finished, let url = state.url, url != committedURL {
            committedURL = url
            onPageCommitted(url)
        }
        guard case .finished = state.phase, let url = state.url else { return }
        if let history {
            if url != recordedURL {
                recordedURL = url
                recordedTitle = state.title
                history.recordVisit(url: url, title: state.title, at: Date(),
                                   actor: tab.isAgentDriven ? "agent" : nil, sessionID: tab.isAgentDriven ? tab.agentSessionID : nil)
            } else if let title = state.title, title != recordedTitle, !tab.isAgentDriven {
                // The store retitles the person's newest visit of a URL; an agent tab's title is not theirs.
                recordedTitle = title
                history.updateTitle(title, for: url)
            }
        }
        if let onPageFinished, url != finishedURL {
            finishedURL = url
            onPageFinished(url)
        }
    }
}
