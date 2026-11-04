import CmuxNextCompat
import Foundation

/// A Chromium window made at an idle moment before a pane needs one, so a
/// pane's first Chromium tab joins a live window (`cmux_tab_add`) instead of
/// building one. Building a Chromium browser window holds the main thread
/// (about 0.8 s in a macOS 26 VM, mostly `-[NSWindow initWithContentRect:]`
/// waiting on the window server; os-smoke, 2026-10-18), which the tab then
/// showed as a stall: every pane's first Chromium tab, not only the process's
/// first (PL-cef-tab, 2026-10-23).
///
/// The spare is a host of the default profile's own store with an
/// about:blank placeholder, in no pane (its window starts at the hidden-tab
/// viewport). The first host the default profile's own store needs takes it
/// (`take`): it is re-keyed, the tab joins its window, and on the next
/// main-actor turn the placeholder closes (`CEFPaneHost.closeSparePlaceholder`).
/// When that tab closes before the window shows it, the host becomes the
/// spare again (`giveBack`). Another profile, a remote machine's store or an
/// incognito window gets a window of its own as before. At most one untaken
/// spare at a time, made only while no other Chromium window is being built;
/// each take, and any window that comes up while none is ready, reports
/// `onNeeded`, so the warmup makes the next spare at the next idle moment (`ChromiumWarmup`).
///
/// The spare is no window request's target (`CEFWindowRequests`): a page
/// or extension that asks for a tab with no window of its own still opens a
/// cmux tab. A tab Chromium puts into the spare's window anyway (an
/// extension's `chrome.tabs.create` targets its last window) waits there
/// (`park`) and is adopted by the first tab that takes the spare.
///
/// The spare window also holds one spare page (`page`): a Chromium browser made at the next idle
/// moment after the window is up, with an empty URL (no navigation, so no history entry), in the
/// background (Chromium counts it hidden), belonging to no tab. A new tab of the default profile's
/// own store takes it instead of `cmux_shim_tab_add` (`CEFPaneHost+SparePage`), which held the main
/// thread about 12 ms per new tab, as Chrome on Android's WarmupManager keeps a spare WebContents
/// outside the tab model. Each take reports `onNeeded`, so the next idle moment makes the next one.
final class CEFSpareWindow {
    static let shared = CEFSpareWindow()
    static let panePrefix = "spare-"

    enum State: String {
        case none, creating, live, taken, closed
    }

    private(set) var host: CEFPaneHost?
    /// Whether a spare was made in this process (`state` says `taken` after its take).
    private var made = false
    /// No spare is ready (a pane took it, or a tab's own window came up first): the next idle
    /// moment may make one (`ChromiumWarmup`).
    var onNeeded: (@MainActor () -> Void)?
    /// Tabs Chromium created in the spare's window before a tab took it.
    private var parked: [(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?)] = []
    /// The untaken spare page, the host whose window it is in (the spare's, or the pane's that took
    /// that window until its placeholder closes) and how it is frozen. At most one.
    private(set) var page: (browser: Int32, host: CEFPaneHost, freeze: CEFPageFreeze)?
    /// Non-nil inside the `tab_add` that makes the spare page: the browsers Chromium created during the
    /// call (`CEFRuntime.browserCreated`). The page's is not a Chromium tab to adopt; any other one is,
    /// once the call returned and the page is known.
    private var createdDuringPage: [(browser: Int32, window: Int32, created: CEFCreatedBy)]?

    var state: State {
        guard let host else { return made ? .taken : .none }
        guard host.placeholder != nil else { return .closed }
        return host.isLive ? .live : host.isCreatingWindow ? .creating : .closed
    }

    func isSpare(_ candidate: CEFPaneHost) -> Bool { host === candidate }

    /// Starts the spare window: true when it started. Chromium must run, no
    /// untaken spare may exist, and no other Chromium window may be on its
    /// way (a window built beside another one raced it, os-smoke 2026-10-18).
    /// With the spare window up, makes its spare page instead (`preparePage`).
    @discardableResult
    func prepare(runtime: CEFRuntime) -> Bool {
        guard runtime.state == .ready, runtime.acceptsNewBrowsers,
              !runtime.hosts.values.contains(where: \.isCreatingWindow) else { return false }
        if let host { return preparePage(in: host, runtime: runtime) }
        made = true
        let key = Self.spareKey()
        let spare = runtime.host(for: key)
        let blank = CEFTab(id: .random(), profile: .default, host: spare, runtime: runtime)
        spare.placeholder = blank
        spare.freezesPlaceholder = true
        spare.add(blank)
        spare.ensureCreated(blank)
        guard spare.isLive || spare.isCreatingWindow else {
            runtime.hosts[key] = nil
            return false
        }
        host = spare
        return true
    }

    /// The spare, re-keyed to `key`, when `key` is a pane of the default
    /// profile's own store; nil otherwise.
    func take(for key: CEFPaneKey, runtime: CEFRuntime) -> CEFPaneHost? {
        guard let spare = host, key.profile == spare.key.profile, key.machineKey == nil, !key.offTheRecord,
              !key.pane.rawValue.hasPrefix(Self.panePrefix), !key.pane.rawValue.hasPrefix(CEFPaneHost.popupPrefix),
              spare.placeholder != nil, spare.isLive || spare.isCreatingWindow else { return nil }
        host = nil
        #if DEBUG || CMUX_BENCH_HOOKS
        runtime.benchMarks.point("cef.spare_taken")
        #endif
        runtime.hosts[spare.key] = nil
        spare.rekey(key)
        runtime.hosts[key] = spare
        onNeeded?()
        return spare
    }

    /// Makes the spare page in the live spare window: in the background (the placeholder stays its
    /// active tab), with an empty URL. Needs `cmux_shim_tab_move_to_window` (fork API 3), which takes it
    /// into a pane's window. True when it was made.
    private func preparePage(in spare: CEFPaneHost, runtime: CEFRuntime) -> Bool {
        guard page == nil, spare.isLive, runtime.forkAPIVersion >= 3, let anchor = spare.placeholder?.browserID,
              let shim = runtime.shim else { return false }
        createdDuringPage = []
        let add = { shim.tabAdd(anchor, "", -1, 0) }
        #if DEBUG || CMUX_BENCH_HOOKS
        let browser = runtime.benchMarks.span("cef.spare_page", add)
        #else
        let browser = add()
        #endif
        let created = createdDuringPage ?? []
        createdDuringPage = nil
        // A tab Chromium made itself during the call (an extension's) goes the way of every such tab,
        // now that the call returned (out of Chromium's creation stack).
        for other in created where other.browser != browser {
            runtime.orphans.adopt(browser: other.browser, window: other.window, created: other.created)
        }
        guard browser != 0 else { return false }
        // No one sees it: no frames, timers or tasks until a tab takes it.
        page = (browser, spare, CEFPageFreeze.freeze(browser, runtime: runtime))
        return true
    }

    /// Chromium created `browser` inside the spare page's `tab_add`: true when it is held until the
    /// call returns (`preparePage`), false outside that call.
    func holdIfMakingPage(_ browser: Int32, window: Int32, created: CEFCreatedBy) -> Bool {
        guard createdDuringPage != nil else { return false }
        createdDuringPage?.append((browser, window, created))
        return true
    }

    /// The spare page for `tab`, which `host` is about to make a browser for in its live window,
    /// thawed, when one is ready and the tab may take it. Only a tab the person sees (`host` shows it)
    /// and no agent drives: a hidden or agent-driven background tab never uses up the page that makes
    /// the person's next new tab fast (the person's input goes before automation). Also the default
    /// profile's own store, no remote machine's store, not incognito; no history to restore (that needs
    /// a browser with no committed entries, `tab_add` with an empty URL); in a pane (not a popup host or
    /// the spare). The page is the tab's from now on; the next idle moment makes the next one.
    func takePage(for tab: CEFTab, in host: CEFPaneHost) -> (browser: Int32, host: CEFPaneHost)? {
        guard let page, host.visibleTab === tab, !tab.isAgentDriven, !tab.awaitsWindowMove, tab.pendingRestore == nil,
              tab.machineStore == nil, host.key.profile == page.host.key.profile, host.key.machineKey == nil,
              !host.key.offTheRecord, !host.isPopupHost, !host.isSpare else { return nil }
        self.page = nil
        page.freeze.thaw(page.browser, runtime: host.runtime)
        #if DEBUG || CMUX_BENCH_HOOKS
        host.runtime.benchMarks.point("cef.spare_page_taken")
        #endif
        onNeeded?()
        return (page.browser, page.host)
    }

    /// The untaken spare page in `host`'s window closes: that window was taken and its placeholder
    /// closes (`closeSparePlaceholder`), or it has no tab left. A pane window never keeps a page no tab
    /// of it shows (an extension would see it, and Chromium might activate it).
    func closePage(in host: CEFPaneHost) {
        guard let page, page.host === host else { return }
        self.page = nil
        host.runtime.shim?.close(page.browser)
        askForPage(runtime: host.runtime)
    }

    /// Chromium closed `browser` before a tab took it (an extension removed it, quit).
    func browserClosed(_ browser: Int32, runtime: CEFRuntime) {
        guard page?.browser == browser else { return }
        page = nil
        askForPage(runtime: runtime)
    }

    /// The spare window waits with no page: the next idle moment makes one. Never while quit stops
    /// Chromium, which closes every browser: that would arm the warmup's idle wait in a quitting app.
    private func askForPage(runtime: CEFRuntime) {
        guard host != nil, runtime.acceptsNewBrowsers else { return }
        onNeeded?()
    }

    /// The tab that took `taken` closed before it joined the window, and only
    /// the placeholder is left: `taken` is the spare again.
    func giveBack(_ taken: CEFPaneHost, runtime: CEFRuntime) {
        guard taken.placeholder != nil, taken.tabs.count == 1 else { return }
        guard host == nil else {
            // Another spare was made since the take: this window has no use left. Closed in a later
            // run-loop callout, never inside the removal that called here.
            MainRunLoopBlock.perform { [weak taken] in
                guard let taken, let blank = taken.placeholder, taken.tabs.count == 1 else { return }
                taken.placeholder = nil
                taken.removed(blank)
                blank.close()
                runtime.hosts[taken.key] = nil
            }
            return
        }
        runtime.hosts[taken.key] = nil
        taken.rekey(Self.spareKey())
        runtime.hosts[taken.key] = taken
        host = taken
        // The pane that showed it is gone: tabs Chromium places must not follow it here.
        if runtime.lastShownHost === taken { runtime.lastShownHost = nil }
    }

    /// Closes the untaken spare: its placeholder goes, and the window with it.
    func drop(runtime: CEFRuntime) {
        // Its page too, and no next one is asked for.
        if let page {
            self.page = nil
            page.host.runtime.shim?.close(page.browser)
        }
        guard let spare = host, let blank = spare.placeholder else { return }
        host = nil
        spare.placeholder = nil
        spare.removed(blank)
        blank.close()
        runtime.hosts[spare.key] = nil
    }

    /// A Chromium window came up (`CEFPaneHost.windowCreated`): with no spare ready, ask for one,
    /// so a Chromium a tab started, not the warm start, gets a spare too. The spare window itself
    /// coming up asks for its spare page.
    func windowCameUp(_ live: CEFPaneHost) {
        guard !live.isPopupHost else { return }
        if host == nil || (live === host && page == nil) { onNeeded?() }
    }

    /// Chromium put `browser` into the spare's window before a tab took it.
    func park(_ browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?) {
        parked.append((browser, disposition, bounds))
    }

    /// The parked tabs, for the host that took the spare.
    func takeParked() -> [(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?)] {
        defer { parked.removeAll() }
        return parked
    }

    private static func spareKey() -> CEFPaneKey {
        CEFPaneKey(pane: BrowserPaneID(rawValue: panePrefix + BrowserTabID.random().rawValue), profile: .default)
    }
}

extension CEFPaneHost {
    /// True while this host is the untaken spare window.
    var isSpare: Bool { CEFSpareWindow.shared.isSpare(self) }

    /// A spare window's host becomes another host key. The caller keeps the
    /// store (`take` and `giveBack` change only the pane): a key of another
    /// profile, machine store or incognito context is refused.
    func rekey(_ key: CEFPaneKey) {
        guard key.profile == self.key.profile, key.machineKey == self.key.machineKey, key.offTheRecord == self.key.offTheRecord else { return }
        self.key = key
    }

    /// `tab` joined this window: a spare window's about:blank placeholder
    /// closes on the next main-actor turn (never inside Chromium's tab
    /// insertion or OnAfterCreated), and the tabs Chromium parked there are
    /// adopted with `tab` as their opener. A popup host closes its own
    /// placeholder in `movePopupsIn`.
    func closeSparePlaceholder(joined tab: CEFTab) {
        guard !isPopupHost, !isSpare, placeholder != nil, placeholder !== tab, tab.browserID != nil else { return }
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab, let blank = self.placeholder, self.tabs.contains(where: { $0 === tab }) else { return }
            // A spare page no tab took goes first: never the active tab, so Chromium's activation stays.
            CEFSpareWindow.shared.closePage(in: self)
            self.placeholder = nil
            // The joined tab is what this host shows: Chromium's activation
            // after the close is this host's own, never a foreign one.
            if let browser = tab.browserID { self.lastActivated = browser }
            self.removed(blank)
            blank.close()
            for parked in CEFSpareWindow.shared.takeParked()
            where self.runtime.tabsByBrowser[parked.browser] == nil && !self.runtime.orphans.ledger.isClosed(parked.browser) {
                self.adoptChromiumTab(browser: parked.browser, disposition: parked.disposition, bounds: parked.bounds)
            }
        }
    }
}
