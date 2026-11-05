import CmuxNextCompat
import CmuxNextDesign
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
    /// that window until its placeholder closes), how it is frozen, and whether it loaded anything (an
    /// extension navigated it, `unownedLoadEvent`). At most one.
    private(set) var page: (browser: Int32, host: CEFPaneHost, freeze: CEFPageFreeze, loaded: Bool)?
    /// Debug Settings > Browser Page Loading > "Make new Chromium tab pages ahead" (`BrowserPageTunables.all`).
    /// Off (the default) until the real-fork journey `chromium-tab-takes-spare-page` passes (#34252): no
    /// spare page is made, no tab takes one, and one left waiting closes at the next new tab (`takePage`).
    nonisolated static let pageSetting = Tunable<Bool>.toggle(
        "browserPage.sparePage", BrowserPageTunables.section, "Make new Chromium tab pages ahead",
        help: "One Chromium page is made ahead at an idle moment, frozen and hidden, and the next new tab you open takes it instead of waiting for Chromium to make its page. A new page is made at the next idle moment after each take. Off makes each tab's page when the tab opens.",
        default: false, code: "CEFSpareWindow.pageSetting")
    static var makesPages: Bool { pageSetting.value }
    /// Memory pressure (warning or critical) holds pages: the waiting one closed when it began
    /// (`holdPages`), and none is made until the level is normal again, as Chrome's Memory Saver
    /// drops a spare renderer first.
    private(set) var pagesHeld = false
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

    /// `waiting` or `none`: the spare page made ahead (`debug.cef` `spare_page`).
    var pageState: String { page == nil ? "none" : "waiting" }
    /// Spare pages a new tab took in this runtime (`debug.cef` `spare_pages_taken`); a page the take refused
    /// (navigated or moved by an extension) is no take.
    private(set) var pagesTaken = 0

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
        guard Self.makesPages, !pagesHeld, page == nil, spare.isLive, runtime.forkAPIVersion >= 3, let anchor = spare.placeholder?.browserID,
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
        page = (browser, spare, CEFPageFreeze.freeze(browser, runtime: runtime), false)
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
    /// the spare). The page is the tab's from now on. Every such tab asks for the next page, at the next
    /// idle moment, whether or not one was ready: a page an extension closed is made again only here.
    func takePage(for tab: CEFTab, in host: CEFPaneHost) -> (browser: Int32, host: CEFPaneHost)? {
        // The switch off (Debug Settings `browserPage.sparePage`): no take, and a page left waiting when it was
        // turned off closes, since nothing will take it.
        guard Self.makesPages else {
            if let page { self.page = nil; host.runtime.shim?.close(page.browser) }
            return nil
        }
        guard host.visibleTab === tab, !tab.isAgentDriven, !tab.awaitsWindowMove, tab.pendingRestore == nil,
              tab.machineStore == nil, host.key.profile == .default, host.key.machineKey == nil,
              !host.key.offTheRecord, !host.isPopupHost, !host.isSpare else { return nil }
        let runtime = host.runtime
        defer { if runtime.acceptsNewBrowsers { onNeeded?() } }
        guard let page, let shim = runtime.shim else { return nil }
        self.page = nil
        // An extension can navigate or move the waiting page (`chrome.tabs.update`, `move`): it is no
        // blank page in its own window any more, and closes.
        guard !page.loaded, Self.isInItsWindow(page.browser, host: page.host, shim: shim) else {
            shim.close(page.browser)
            return nil
        }
        page.freeze.thaw(page.browser, runtime: runtime)
        return (page.browser, page.host)
    }

    /// The taken page joined its tab's window and is the tab's browser (`CEFPaneHost.joinSparePage`): one take.
    func pageJoined(runtime: CEFRuntime) {
        pagesTaken += 1
        #if DEBUG || CMUX_BENCH_HOOKS
        runtime.benchMarks.point("cef.spare_page_taken")
        #endif
    }

    /// The waiting page is in the window it was made in: its host's (another tab of that window names it).
    private static func isInItsWindow(_ browser: Int32, host: CEFPaneHost, shim: CEFShimLibrary) -> Bool {
        guard let anchor = host.anchorBrowser, anchor != browser else { return false }
        let window = shim.tabWindowID(browser)
        return window != 0 && window == shim.tabWindowID(anchor)
    }

    /// A load event of a browser no tab owns (`CEFRuntime.handle`): when it is the waiting page's, the
    /// page was navigated (it was made with no URL, so it loads nothing of its own).
    func unownedLoadEvent(_ event: CEFShimEvent) {
        guard let browser = event.browserID, page?.browser == browser else { return }
        if case .loadingState = event { return }
        page?.loaded = true
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

    /// Chromium closed `browser` before a tab took it: an extension removed it, or quit closed it. A
    /// close cmux did not start asks for no new page (an extension that closes every blank tab would
    /// make one each idle moment, without end): the next take asks (`takePage`).
    func browserClosed(_ browser: Int32) {
        guard page?.browser == browser else { return }
        page = nil
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

    /// Under memory pressure (`held`) the waiting page closes and none is made; back to normal, the
    /// spare window asks for its page again at the next idle moment (`onNeeded`).
    func holdPages(_ held: Bool) {
        guard held != pagesHeld else { return }
        pagesHeld = held
        if held, let page {
            self.page = nil
            page.host.runtime.shim?.close(page.browser)
        } else if !held, host != nil, Self.makesPages {
            onNeeded?()
        }
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
        if host == nil || (live === host && page == nil && Self.makesPages) { onNeeded?() }
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
    var isSpare: Bool { runtime.spareWindow.isSpare(self) }

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
            self.runtime.spareWindow.closePage(in: self)
            self.placeholder = nil
            // The joined tab is what this host shows: Chromium's activation
            // after the close is this host's own, never a foreign one.
            if let browser = tab.browserID { self.lastActivated = browser }
            self.removed(blank)
            blank.close()
            for parked in self.runtime.spareWindow.takeParked()
            where self.runtime.tabsByBrowser[parked.browser] == nil && !self.runtime.orphans.ledger.isClosed(parked.browser) {
                self.adoptChromiumTab(browser: parked.browser, disposition: parked.disposition, bounds: parked.bounds)
            }
        }
    }
}
