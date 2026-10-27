public import CmuxNextBrowser
import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation
import WebKit
public import CmuxNextWakeups

/// Restored WebKit pages that start from their saved history (cx-p0im9). The page is made
/// blank; once this Mac's daemon answers with the tab's saved history (`BrowserTabService`),
/// the page restores WebKit's own state, which brings back its real back list and each page's
/// state, or else loads its address. Either way the shown page loads once. A read slower than
/// `budget` loads the address, so a page never waits on the daemon for long.
public final class BrowserHistoryStarts {
    /// How long a held page waits for its saved history before it loads its address.
    public static let budget: Duration = .seconds(1)
    /// How long a restored page's first load (or a local page's folder load) is waited on before its
    /// saved scroll position and entries are given up (PageWaiters' bound; a closed page ends the wait at once).
    static let loadLimit: Duration = .seconds(60)
    /// The owner of a held page's budget deadline in the board and the wakeup ledger.
    static let budgetOwner = "BrowserHistoryStarts.budget"

    private struct Waiting {
        weak var page: WebKitTab?
        let url: URL
        /// The budget: loads the address when the read is slower (cancelled when it answers).
        let timer: MainDeadline
    }

    /// The app's one deadline scheduler: each held page's budget is a deadline on it.
    private let deadlines: MainDeadlineScheduler
    private var waiting: [String: Waiting] = [:]
    /// How each held page started, by tab id (`debug.browser.page_status` `history_start`).
    public var outcomes: [String: String] = [:]
    /// Tabs whose new page restored its engine's own history, until `takeEngineRestored`.
    private var engineRestored: Set<String> = []

    /// Makes the set of held pages (one per app, owned by the browser tab service).
    ///
    /// - Parameter deadlines: The app's one deadline scheduler (`AppServices.mainDeadlines`), for each held
    ///   page's budget.
    public init(deadlines: MainDeadlineScheduler) {
        self.deadlines = deadlines
    }

    /// Notes that tab `tabID`'s new page was made from its engine's own history (a Chromium
    /// page, made from it before it exists).
    public func markEngineRestored(_ tabID: String) {
        engineRestored.insert(tabID)
    }

    /// Forgets tab `tabID`'s mark when its page stops being tracked before the mark was taken.
    /// A held page still starts (its timer loads its address).
    public func forget(_ tabID: String) {
        engineRestored.remove(tabID)
    }

    /// True once after tab `tabID`'s new page was made from its engine's own history: it then gets
    /// no saved entries on top now. Chromium restores as its page is made, after this; once its first
    /// load ends the page scrolls to the position saved at quit, and a page that came back without
    /// its list (a fork that cannot restore, a refused state) gets the saved entries as before.
    public func takeEngineRestored(_ tabID: String, page: any BrowserTab, saved: FrontendBrowserHistory?) -> Bool {
        guard engineRestored.remove(tabID) != nil else { return false }
        guard page.engineKind == .cef, let saved, saved.entries.indices.contains(saved.index),
              let loads = page as? any BrowserPageWaiting else { return true }
        // task-owner: one restored page's first load, bounded by loadLimit; the page's close ends the wait at once
        // main-hop-allow: when(phase:) is the page's main-actor keyed wait (PageWaiters, R-wait); its resume scrolls and restores the page in the load's order
        Task { [weak loads] in
            // R-wait: the page's keyed phase wait, read only on a load-phase change.
            guard await loads?.when(phase: { Self.ended($0) }, timeout: Self.loadLimit) != nil, let page = loads,
                  page.state.url?.absoluteString == saved.entries[saved.index].url else { return }
            if let y = saved.entries[saved.index].scrollY { page.scrollOnLoad(to: y) }
            if !page.state.canGoBack, !page.state.canGoForward, saved.entries.count > 1,
               let restoring = page as? any BrowserTab & BrowserSessionRestoring, let session = BrowserHistoryWriter.session(saved) {
                restoring.restoreSession(session.entries, current: session.current)
            }
        }
        return true
    }

    /// Holds blank `page` of tab `tabID` until its saved history is read, at most `budget`; it then shows `url`.
    public func hold(_ page: WebKitTab, url: URL, tabID: String) {
        waiting[tabID]?.timer.cancel()
        // A mark left by a Chromium page that could not be made is not this page's.
        engineRestored.remove(tabID)
        // R-timer: a visible, flexible deadline (the person sees the blank page until it starts); the read's answer cancels it.
        let timer = MainDeadline(owner: Self.budgetOwner, workClass: .visible, scheduler: deadlines)
        timer.schedule(after: Self.budget) { [weak self] in self?.start(tabID, saved: nil) }
        waiting[tabID] = Waiting(page: page, url: url, timer: timer)
    }

    /// Starts the page of `tabID` if it still waits: through `saved`'s engine state when it was
    /// saved at the page's address, else at the address. True when the engine state restored it.
    @discardableResult
    public func start(_ tabID: String, saved: FrontendBrowserHistory?) -> Bool {
        guard let entry = waiting.removeValue(forKey: tabID) else { return false }
        entry.timer.cancel()
        guard let page = entry.page else { return false }
        // A navigation that started while the page waited (a deferred page's start, an agent's
        // load) wins: the page keeps it.
        guard page.webView.url == nil, page.state.url == nil else {
            outcomes[tabID] = "navigated"
            return false
        }
        let files = BrowserHistoryWriter.keepsFileAccess(saved?.entries.compactMap { URL(string: $0.url) } ?? [], shown: entry.url)
        if let state = BrowserHistoryWriter.restoreState(saved, at: entry.url, engine: .webkit), files {
            guard entry.url.isFileURL else {
                guard restore(page, state, saved: saved, at: entry.url, tabID: tabID) else { return false }
                engineRestored.insert(tabID)
                return true
            }
            // A local page first loads with read access to its folder, which its restored entries
            // (all in that folder) then share; restored without it, WebKit would read them with
            // access to every file. The restore waits for that load to commit, so it replaces the
            // load's entry instead of the load committing after it as one more entry, and comes
            // before the page's scripts run (Back pressed then would find no entries).
            page.load(entry.url)
            outcomes[tabID] = "engine-waiting-file"
            // No saved entries on top: a local page's could not navigate (WebKit refuses a
            // scripted replace to a file), whether or not the restore takes.
            engineRestored.insert(tabID)
            // task-owner: one local page's folder load, bounded by loadLimit; the page's close ends the wait at once
            // main-hop-allow: when(phase:) is the page's main-actor keyed wait (PageWaiters, R-wait); the restore must replace the load's entry before the page's scripts run
            Task { [weak self, weak page] in
                // The load's phase, not its address: WebKit reports the address as the load is
                // asked for, before it starts. R-wait: the page's keyed phase wait (PageWaiters).
                let committed = await page?.when(phase: { Self.committed($0) }, timeout: Self.loadLimit) != nil
                // A page the person sent elsewhere meanwhile keeps where they went.
                guard committed, let self, let page, page.state.url?.absoluteString == entry.url.absoluteString else {
                    self?.outcomes[tabID] = "navigated"
                    return
                }
                self.restore(page, state, saved: saved, at: entry.url, tabID: tabID)
            }
            return true
        }
        outcomes[tabID] = saved == nil ? "address" : saved?.engineState == nil ? "address-no-state" : "address-file-access"
        page.load(entry.url)
        return false
    }

    private static func ended(_ phase: BrowserLoadPhase) -> Bool {
        switch phase {
        case .finished, .failed: true
        case .idle, .provisional, .committed: false
        }
    }

    private static func committed(_ phase: BrowserLoadPhase) -> Bool {
        switch phase {
        case .committed, .finished, .failed: true
        case .idle, .provisional: false
        }
    }

    @discardableResult
    private func restore(_ page: WebKitTab, _ state: BrowserRestoreState, saved: FrontendBrowserHistory?, at url: URL, tabID: String) -> Bool {
        if page.restore(state), page.webView.backForwardList.currentItem?.url.absoluteString == url.absoluteString {
            // WebKit keeps the scroll position it last recorded for the page, which can be
            // older than the one measured at quit.
            if let saved, let y = saved.entries[saved.index].scrollY { page.scrollOnLoad(to: y) }
            outcomes[tabID] = "engine"
            return true
        }
        outcomes[tabID] = "address-state-refused"
        // A local page already shows its address from the folder load.
        if !url.isFileURL { page.load(url) }
        return false
    }
}
