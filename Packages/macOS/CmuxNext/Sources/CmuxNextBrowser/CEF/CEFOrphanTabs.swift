import struct CmuxSafeConcurrency.OwnerReference
import Foundation

/// Tabs Chromium creates itself (target=_blank, window.open,
/// chrome.tabs.create, an options page) and their way into a cmux pane.
/// Owns the browsers that wait for a pane (`ledger`) and the ones that wait
/// for the fork to insert them into a pane window (`unplaced`, fork API 8).
@MainActor
final class CEFOrphanTabs {
    /// The runtime, which owns this as `CEFRuntime.orphans`.
    private let runtimeReference: OwnerReference<CEFRuntime>
    /// The runtime; nil (reported) only once it is gone, and then no tab is adopted.
    private var runtime: CEFRuntime? { runtimeReference.resolve() }
    /// Browsers Chromium created while their pane's window was still being
    /// created, and browsers that closed before cmux registered them.
    var ledger = CEFAdoptionLedger()
    /// Tabs Chromium created in no window or in a window cmux does not host,
    /// waiting for the fork to insert them into a pane window (fork API 8).
    var unplaced: [Int32: CEFCreatedBy] = [:]

    init(runtime: CEFRuntime) {
        runtimeReference = CEFRuntime.childReference(runtime)
    }

    /// A browser Chromium created itself in `window`. When that window is
    /// being created for a pane (extensions open welcome tabs as soon as the
    /// first window exists, before its OnAfterCreated), the tab waits for the
    /// pane. A tab in no window yet (a popup Chromium still places) or in a
    /// window cmux does not host waits for the fork to insert it into a pane
    /// window (fork API 8: `placeUnplaced`); older forks give it a Chromium
    /// window of its own, and the tab moves into the most recently shown
    /// pane (the window guard hides that window).
    func adopt(browser: Int32, window: Int32, created: CEFCreatedBy = .none) {
        // A popup window's tab may already belong to its popup host (fork API 11).
        guard let runtime, !ledger.isClosed(browser), runtime.tabsByBrowser[browser] == nil else { return }
        guard let disposition = linkDisposition(browser: browser, created: created, in: runtime) else { return }
        if let host = runtime.hosts.values.first(where: { $0.owns(window: window) }) {
            let placement = runtime.takePlacement(browser: browser, window: window, fallback: disposition, created: created)
            host.adoptChromiumTab(browser: browser, disposition: placement.disposition, bounds: placement.bounds)
            return
        }
        if runtime.hosts.values.contains(where: \.isCreatingWindow) {
            ledger.enqueue(Orphan(browser: browser, window: window))
            return
        }
        if runtime.forkAPIVersion >= 8 {
            unplaced[browser] = created
            return
        }
        // The opener's pane (a popup, a link); else the last shown pane.
        moveIntoShownPane(browser: browser, disposition: disposition, preferred: runtime.tabsByBrowser[created.opener]?.host)
    }

    /// The fork inserted `browser` into `window` (fork API 8): a tab that
    /// waited for a pane window is adopted there.
    func placeUnplaced(browser: Int32, window: Int32) {
        guard let runtime, let created = unplaced[browser], runtime.tabsByBrowser[browser] == nil,
              let host = runtime.hosts.values.first(where: { $0.owns(window: window) }) else { return }
        unplaced[browser] = nil
        guard let disposition = linkDisposition(browser: browser, created: created, in: runtime) else { return }
        let placement = runtime.takePlacement(browser: browser, window: window, fallback: disposition, created: created)
        // The event arrives inside Chromium's tab strip notification, which
        // forbids tab strip changes (the host may select the new tab): adopt
        // on the next main-actor turn.
        Task { @MainActor [weak self, weak host] in
            guard let self, let host, let runtime = self.runtime, runtime.tabsByBrowser[browser] == nil, !self.ledger.isClosed(browser) else { return }
            host.adoptChromiumTab(browser: browser, disposition: placement.disposition, bounds: placement.bounds)
        }
    }

    /// How a tab Chromium created for a page opens (`CEFLinkClicks`); nil
    /// when a modified click was mapped to the current tab or a download:
    /// the new browser closes and its opener loads or downloads the link.
    private func linkDisposition(browser: Int32, created: CEFCreatedBy, in runtime: CEFRuntime) -> BrowserNewTabDisposition? {
        // The shim matched the popup's target URL, disposition and gesture
        // as one record (OnBeforePopup), so a URL never pairs with another
        // popup's disposition.
        let url = created.url
        let links = runtime.windowRequests.linkClicks.context()
        switch links.placement(for: created.disposition, source: created.opener, userGesture: created.userGesture) {
        case .tab(let disposition):
            return disposition
        case .opener:
            guard let url, let link = URL(string: url), let opener = runtime.tabsByBrowser[created.opener] else { return .foregroundTab }
            // Never inside Chromium's tab insertion (OnAfterCreated, the tab
            // strip notification): close and load on the next turn.
            Task { @MainActor [weak runtime, weak opener] in
                runtime?.shim?.close(browser)
                opener?.load(link)
            }
            return nil
        case .download:
            guard let url, runtime.tabsByBrowser[created.opener] != nil else { return .foregroundTab }
            // As for `.opener`: never inside Chromium's tab insertion.
            Task { @MainActor [weak runtime] in
                runtime?.shim?.close(browser)
                _ = runtime?.downloads.download(url, browser: created.opener)
            }
            return nil
        case .chromium:
            return .foregroundTab
        }
    }

    /// A pane's window now exists: adopt the tabs that were created in it
    /// before its first browser reported.
    func windowBecameLive(_ host: CEFPaneHost) {
        guard let runtime else { return }
        let waiting = ledger.takeWaiting()
        for orphan in waiting {
            if host.owns(window: orphan.window) {
                let placement = runtime.takePlacement(browser: orphan.browser, window: orphan.window, fallback: .foregroundTab)
                host.adoptChromiumTab(browser: orphan.browser, disposition: placement.disposition, bounds: placement.bounds)
            } else if runtime.hosts.values.contains(where: \.isCreatingWindow) {
                ledger.enqueue(orphan)
            } else if runtime.forkAPIVersion >= 8 {
                unplaced[orphan.browser] = CEFCreatedBy.none
            } else {
                moveIntoShownPane(browser: orphan.browser, disposition: .foregroundTab)
            }
        }
    }

    /// `browser` waited in a spare window that closes before a tab took it (`CEFSpareWindow.drop`):
    /// it moves into the last shown pane, as a tab in a window cmux does not host does on a fork
    /// before API 8, and closes when no pane can take it.
    func rehome(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?) {
        moveIntoShownPane(browser: browser, disposition: disposition, bounds: bounds)
    }

    /// `browser` closed before cmux registered a tab for it: it must never
    /// be adopted.
    func closedUnregistered(_ browser: Int32) {
        ledger.closedUnregistered(browser)
        unplaced[browser] = nil
    }

    /// Runs on the next main-actor turn: this is reached from
    /// OnAfterCreated, inside Chromium's tab insertion, where moving the tab
    /// to another tab strip would re-enter it.
    private func moveIntoShownPane(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect? = nil,
                                   preferred: CEFPaneHost? = nil) {
        Task { @MainActor [weak self, weak preferred] in
            self?.moveIntoShownPaneNow(browser: browser, disposition: disposition, bounds: bounds, preferred: preferred)
        }
    }

    private func moveIntoShownPaneNow(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?,
                                      preferred: CEFPaneHost?) {
        // Chromium may have closed it meanwhile (a tab an extension opened
        // and removed at once): adopting it would leave a ghost tab.
        guard let runtime, runtime.tabsByBrowser[browser] == nil, !ledger.isClosed(browser) else { return }
        let hosts = runtime.hosts
        guard let shim = runtime.shim, runtime.forkAPIVersion >= CEFPaneHost.tabMoveForkAPI,
              let host = preferred.flatMap({ $0.isLive ? $0 : nil }) ?? runtime.lastShownHost ?? hosts.values.first(where: { $0.isLive }),
              let anchor = host.anchorBrowser,
              // The fork's answer in process; in host mode the post's (sent), as `CEFPaneHost.movePopupsIn`.
              shim.tabMoveToWindow(browser, anchor, -1) == 1 else {
            runtime.logger.error("CEF browser \(browser) in a window cmux does not host; closing it")
            runtime.shim?.close(browser)
            return
        }
        host.adoptChromiumTab(browser: browser, disposition: disposition, bounds: bounds)
    }
}
