import CmuxNextCompat
import Foundation

/// Chromium windows made at an idle moment before a pane needs one, so a
/// pane's first Chromium tab joins a live window (`cmux_tab_add`) instead of
/// building one. Building a Chromium browser window holds the main thread
/// (about 0.8 s in a macOS 26 VM, mostly `-[NSWindow initWithContentRect:]`
/// waiting on the window server; os-smoke, 2026-10-18), which the tab then
/// showed as a stall: every pane's first Chromium tab, not only the process's
/// first (PL-cef-tab, 2026-10-23).
///
/// One spare per ``Kind``: `browser`, a host of the default profile's own
/// store, and `pages`, a host of the cmux pages' in-memory profile
/// (`pagesProfile`, `CEFEngine.beginPagesProfile()`), so a cmux page's key takes a
/// live window too. One spare per kind is cmux's own choice
/// (p13-webui design D), not Chrome's: Chrome keeps one spare renderer, of
/// one BrowserContext's default StoragePartition, and a spare asked for
/// another context replaces it, because a spare of one store cannot serve
/// another (`content/browser/renderer_host/spare_render_process_host_manager_impl.h`).
/// Each spare holds a placeholder tab, in no pane (its window starts at the
/// hidden-tab viewport). With the `rendererlessSpareWindow` feature, where the
/// fork can, the placeholder has no renderer
/// and never navigates (`cmux_shim_create_placeholder_window`),
/// so a spare costs a window and no renderer process; on an older fork it is
/// an about:blank page frozen through DevTools (`CEFTab.freezeNeverShownPage`).
/// The first host a spare's store needs
/// takes it (`take`): it is re-keyed, the tab joins its window, and on the
/// next main-actor turn the placeholder closes (`CEFPaneHost.closeSparePlaceholder`).
/// When that tab closes before the window shows it, the host becomes the
/// spare again (`giveBack`). Another profile, a remote machine's store or an
/// incognito window gets a window of its own as before. At most one untaken
/// spare per kind, made only while no other Chromium window is being built;
/// each take, and any window that comes up while a wanted kind has none,
/// reports `onNeeded`. The report only posts the refill: the warmup builds the
/// next spare in an idle task of the main-thread scheduler with a 500 ms
/// `maxDelay` (`ChromiumWarmup`, `MainWorkScheduler.postIdle`), never in the
/// key's turn or its input response and only after 750 ms with no input, and
/// past the delay as background work, so the next Cmd-T still finds one in a
/// busy app. Chrome
/// also refills its spare renderer after the take, off the navigation's path
/// (`SpareRenderProcessHostManagerImpl::PrepareForFutureRequests`).
///
/// Under memory pressure no new spare is made (Chrome's
/// `content/browser/renderer_host/spare_render_process_host_manager_impl.cc`, which keeps an existing
/// spare): the warmup's memory consumer holds the spares at warning and critical (`holdSpareWindows`),
/// and until it lets go at normal none is made, given back or asked for. Critical also closes the
/// untaken ones (`closeUntakenSpareWindows`; a tab parked in one moves to a shown pane).
///
/// Chrome keeps one spare renderer; with `chromiumOneSpareRenderer` cmux keeps one too (``placeholderIsTheSpare``).
///
/// A spare is no window request's target (`CEFWindowRequests`): a page
/// or extension that asks for a tab with no window of its own still opens a
/// cmux tab. A tab Chromium puts into a spare's window anyway (an
/// extension's `chrome.tabs.create` targets its last window) waits there
/// (`park`) and is adopted by the first tab that takes that spare.
///
/// With the Chromium Host the spare stays (`ChromiumWarmup.Placement.host`): content
/// makes its spare RenderProcessHost only after a navigation took a process
/// (`SpareRenderProcessHostManagerImpl::PrepareForFutureRequests`; `IsSpareProcessKeptAtAllTimes`
/// only refills a taken one), so after a warm start only the spare's window, and its placeholder's
/// renderer without `rendererlessSpareWindow`, are warm for the first tab.
/// The bench-only `chromiumHostNoSpareWindow` drops it, the arm that measures the host without it.
///
/// The runtime owns the one instance (`CEFRuntime.spareWindow`).
final class CEFSpareWindow {
    static let panePrefix = "spare-"

    /// The store a spare serves.
    enum Kind: String, CaseIterable {
        /// The default browser profile's own store.
        case browser
        /// The cmux pages' in-memory profile (`pagesProfile`).
        case pages
    }

    enum State: String {
        case none, creating, live, taken, closed
    }

    private var hosts: [Kind: CEFPaneHost] = [:]
    /// The kinds a spare was made of in this process (`state` says `taken` after its take).
    private var made: Set<Kind> = []
    /// The cmux pages' off-the-record profile (`CEFEngine.beginPagesProfile()`): its keys take the
    /// `pages` spare. Nil until the engine makes it; no `pages` spare is made before.
    var pagesProfile: BrowserProfileID?
    /// Whether the warmup keeps a `pages` spare (cmux pages use Chromium and the
    /// `pagesSpareWindow` feature is on). Turning it off closes an untaken one.
    private(set) var wantsPages = false
    /// Whether a spare's placeholder is made with no renderer where the fork can (the
    /// `rendererlessSpareWindow` feature, `CEFEngine.setRendererlessSpareWindows`); off, every spare
    /// holds the frozen about:blank page. Read when a spare's window is built.
    var rendererlessPlaceholders = false
    /// The default-off feature `chromiumOneSpareRenderer` (`CEFEngine.setOneSpareRenderer`): at most one
    /// Chromium spare renderer (``placeholderIsTheSpare``). Set before Chromium starts.
    var oneSpareRenderer = false
    /// Whether a spare's placeholder holds a renderer in the running Chromium: true until a start
    /// finds renderer-less placeholders on and the fork able to make them (``chromiumStarting(placeholderSupported:)``).
    private(set) var placeholdersHoldRenderers = true
    /// Memory pressure above normal (`setHeld`): no spare is made, given back or asked for.
    private(set) var isHeld = false
    /// No spare of a wanted kind is ready (a pane took it, or a window came up first): the warmup
    /// posts the refill as an idle task (`ChromiumWarmup`). Called in the take's turn, so it must
    /// only post, never build a window.
    var onNeeded: (@MainActor () -> Void)?
    // memory: fixed: 2 keys (`Kind`), each a list of (browser id, disposition, bounds) values of a few
    // bytes, emptied when its spare is taken (`takeParked`) or dropped (`drop`); the spare windows
    // themselves follow memory pressure through ChromiumWarmup's SpareMemoryConsumer.
    /// Tabs Chromium created in a spare's window before a tab took it, by the spare's kind.
    private var parked: [Kind: [(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?)]] = [:]
    /// Windows built for a key a spare serves because no spare of its kind was ready
    /// (`debug.cef` `window_built_on_key_turn`; a ready spare keeps it at 0).
    private(set) var windowsBuiltOnKeyTurn = 0
    /// `cef.create_browser`: the pair around each window the shim is asked to build, spares and panes alike
    /// (`CEFPaneHost.ensureCreated`), closed at the host's created reply in host mode (`CEFRuntime.browserCreated`).
    var createTrace = CEFCreateBrowserTrace()

    /// The untaken spare of `kind`, nil when none is up.
    func host(of kind: Kind) -> CEFPaneHost? { hosts[kind] }

    /// How many untaken spares are up or being built.
    var untakenCount: Int { hosts.count }

    /// `none`, `creating`, `live`, `taken` or `closed` for the spare of `kind`.
    func state(of kind: Kind) -> State {
        guard let host = hosts[kind] else { return made.contains(kind) ? .taken : .none }
        guard host.placeholder != nil else { return .closed }
        return host.isLive ? .live : host.isCreatingWindow ? .creating : .closed
    }

    func isSpare(_ candidate: CEFPaneHost) -> Bool { hosts.values.contains { $0 === candidate } }

    /// The spare kind that serves `key`, nil when none does: a pane of the default profile's own
    /// store, or of the pages profile. A remote machine's store, an incognito window, a popup or
    /// a spare's own key never takes one.
    func kind(for key: CEFPaneKey) -> Kind? {
        guard key.machineKey == nil, !key.pane.rawValue.hasPrefix(Self.panePrefix),
              !key.pane.rawValue.hasPrefix(CEFPaneHost.popupPrefix) else { return nil }
        if key.offTheRecord {
            guard let pagesProfile, key.profile == pagesProfile else { return nil }
            return .pages
        }
        return key.profile == .default ? .browser : nil
    }

    /// The kinds the warmup keeps a spare of: `browser` always, `pages` while `wantsPages`, the
    /// pages profile exists and its placeholder would not be a second spare renderer (``placeholderIsTheSpare``).
    var wantedKinds: [Kind] {
        Kind.allCases.filter { $0 == .browser || (wantsPages && pagesProfile != nil && !placeholderIsTheSpare) }
    }

    /// The one Chromium spare renderer is a spare window's placeholder (`chromiumOneSpareRenderer` on
    /// while placeholders hold a renderer): Chromium's own spare is off and only the `browser` kind is
    /// kept. Chrome keeps one spare renderer, never one per profile
    /// (`content/browser/renderer_host/spare_render_process_host_manager_impl.h`). Off, Chromium's
    /// spare is the one and the placeholders hold none, or the feature is off.
    var placeholderIsTheSpare: Bool { oneSpareRenderer && placeholdersHoldRenderers }

    /// Chromium starts (`CEFRuntime.initialize`): whether a spare's placeholder will hold a renderer
    /// in it, which says whether Chromium keeps its own spare renderer.
    ///
    /// - Parameter placeholderSupported: The fork makes renderer-less placeholders (`cmux_shim_placeholder_supported`).
    /// - Returns: Whether Chromium keeps its own spare renderer (false: `CEFSwitches.chromiumSpareOff`).
    func chromiumStarting(placeholderSupported: Bool) -> Bool {
        placeholdersHoldRenderers = !(rendererlessPlaceholders && placeholderSupported)
        return !placeholderIsTheSpare
    }

    /// The untaken spares, `browser` first, each with the renderer client ids of its placeholder
    /// (empty while the placeholder has none: renderer-less, or not made yet).
    var untakenSpares: [(kind: Kind, rendererClients: [Int32])] {
        Kind.allCases.compactMap { kind in
            guard let host = hosts[kind] else { return nil }
            guard case .chromiumRendererClients(let clients)? = host.placeholder?.contentProcesses else { return (kind, []) }
            return (kind, clients)
        }
    }

    /// The first wanted kind with no untaken spare, nil when every wanted kind has one.
    var missingKind: Kind? { wantedKinds.first { hosts[$0] == nil } }

    /// Whether to keep a `pages` spare; false closes an untaken one.
    func setWantsPages(_ wants: Bool, runtime: CEFRuntime) {
        wantsPages = wants
        if !wants { drop(.pages, runtime: runtime) }
    }

    /// Starts the spare of the first wanted kind with none (`missingKind`): true when it started.
    @discardableResult
    func prepareNext(runtime: CEFRuntime) -> Bool {
        guard let kind = missingKind else { return false }
        return prepare(kind, runtime: runtime)
    }

    /// Holds the spares while memory pressure is above normal: until `held` is false again none is
    /// made, given back or asked for; the untaken ones stay until critical pressure closes them
    /// (`drop`). Letting go asks for nothing itself: the warmup makes the next spare at its next idle
    /// moment.
    func setHeld(_ held: Bool) {
        isHeld = held
    }

    /// Starts the spare window of `kind`: true when it started. Chromium must
    /// run, no spare may be held for memory pressure, no untaken spare of `kind` may exist, and no
    /// other Chromium window may be on its way (a window built beside another one raced it,
    /// os-smoke 2026-10-18). While ``placeholderIsTheSpare``, only a `browser` spare is made.
    @discardableResult
    func prepare(_ kind: Kind, runtime: CEFRuntime) -> Bool {
        guard !isHeld, kind == .browser || !placeholderIsTheSpare, hosts[kind] == nil, let key = spareKey(kind),
              runtime.state == .ready, runtime.acceptsNewBrowsers,
              !runtime.hosts.values.contains(where: \.isCreatingWindow) else { return false }
        made.insert(kind)
        let spare = runtime.host(for: key)
        let blank = CEFTab(id: .random(), profile: key.profile, host: spare, runtime: runtime)
        spare.placeholder = blank
        spare.quietsPlaceholder = true
        spare.add(blank)
        spare.ensureCreated(blank)
        guard spare.isLive || spare.isCreatingWindow else {
            runtime.hosts[key] = nil
            return false
        }
        hosts[kind] = spare
        if spare.isLive { runtime.launchMarks.send(.spareWindowReady) }
        return true
    }

    /// The spare that serves `key` (`kind(for:)`), re-keyed to `key`; nil when none is ready.
    func take(for key: CEFPaneKey, runtime: CEFRuntime) -> CEFPaneHost? {
        guard let kind = kind(for: key), let spare = hosts[kind], key.profile == spare.key.profile,
              spare.placeholder != nil, spare.isLive || spare.isCreatingWindow else { return nil }
        hosts[kind] = nil
        #if DEBUG || CMUX_BENCH_HOOKS
        runtime.benchMarks.point(kind == .browser ? "cef.spare_taken" : "cef.pages_spare_taken")
        #endif
        runtime.hosts[spare.key] = nil
        spare.rekey(key)
        runtime.hosts[key] = spare
        onNeeded?()
        return spare
    }

    /// The tab that took `taken` closed before it joined the window, and only
    /// the placeholder is left: `taken` is its kind's spare again.
    func giveBack(_ taken: CEFPaneHost, runtime: CEFRuntime) {
        guard taken.placeholder != nil, taken.tabs.count == 1, let kind = kind(for: taken.key),
              let spareKey = spareKey(kind) else { return }
        guard !isHeld, hosts[kind] == nil, wantedKinds.contains(kind) else {
            // Memory pressure holds the spares, another spare of its kind was made since the take,
            // or the kind is no longer wanted: this window has no use left. Closed in a later
            // run-loop callout, never inside the removal that called here.
            MainRunLoopBlock.perform { [weak taken] in
                guard let taken, let blank = taken.placeholder, taken.tabs.count == 1 else { return }
                taken.placeholder = nil
                // Its last tab leaves: `removed` takes it out of the routing table (`CEFRuntime.hostEmptied`).
                taken.removed(blank)
                blank.close()
            }
            return
        }
        runtime.hosts[taken.key] = nil
        taken.rekey(spareKey)
        runtime.hosts[taken.key] = taken
        hosts[kind] = taken
        // The pane that showed it is gone: tabs Chromium places must not follow it here.
        if runtime.lastShownHost === taken { runtime.lastShownHost = nil }
    }

    /// Closes the untaken spare of `kind` (every kind when nil): its placeholder goes, and the
    /// window with it. Tabs Chromium parked there (`park`) are no spare's: they leave for a shown
    /// pane, as a tab in a window cmux does not host does (`CEFOrphanTabs.rehome`), and no later
    /// spare of that kind adopts them.
    func drop(_ kind: Kind? = nil, runtime: CEFRuntime) {
        for each in kind.map({ [$0] }) ?? Kind.allCases {
            guard let spare = hosts[each], let blank = spare.placeholder else { continue }
            hosts[each] = nil
            let waiting = parked.removeValue(forKey: each) ?? []
            spare.placeholder = nil
            // No longer a spare: `removed` takes it out of the routing table (`CEFRuntime.hostEmptied`).
            spare.removed(blank)
            blank.close()
            for tab in waiting {
                runtime.orphans.rehome(browser: tab.browser, disposition: tab.disposition, bounds: tab.bounds)
            }
        }
    }

    /// The Chromium Host ended (`CEFRuntime.hostEnded`): every spare's window and the tabs parked there
    /// went with it, so nothing is rehomed (no browser id of the dead host reaches the next one) and the spares close.
    func hostEnded(runtime: CEFRuntime) {
        parked = [:]
        drop(runtime: runtime)
    }

    /// `ensureCreated` asked Chromium for a window of `key`: one a spare would have served counts
    /// in `windowsBuiltOnKeyTurn`. A spare's own window never counts.
    func noteWindowBuilt(for key: CEFPaneKey) {
        guard kind(for: key) != nil else { return }
        windowsBuiltOnKeyTurn += 1
    }

    /// A Chromium window came up (`CEFPaneHost.windowCreated`): with a wanted kind that has no
    /// spare, ask for one, so a Chromium a tab started, not the warm start, gets spares too, and
    /// the next kind's spare follows the one that just came up.
    /// A spare's own window marks `cef.spare_window_ready` (once per process, ``CEFLaunchMarks``).
    func windowCameUp(_ live: CEFPaneHost) {
        if isSpare(live) { live.runtime.launchMarks.send(.spareWindowReady) }
        if !isHeld, missingKind != nil, !live.isPopupHost { onNeeded?() }
    }

    /// Chromium put `browser` into the window of `spare` before a tab took it.
    func park(_ browser: Int32, in spare: CEFPaneHost, disposition: BrowserNewTabDisposition, bounds: CGRect?) {
        guard let kind = hosts.first(where: { $0.value === spare })?.key else { return }
        parked[kind, default: []].append((browser, disposition, bounds))
    }

    /// The tabs parked in the spare that now serves `key`, for the host that took it.
    func takeParked(for key: CEFPaneKey) -> [(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?)] {
        guard let kind = kind(for: key) else { return [] }
        return parked.removeValue(forKey: kind) ?? []
    }

    /// A new spare key of `kind`; nil for `pages` before the pages profile exists.
    private func spareKey(_ kind: Kind) -> CEFPaneKey? {
        let pane = BrowserPaneID(rawValue: Self.panePrefix + kind.rawValue + "-" + BrowserTabID.random().rawValue)
        switch kind {
        case .browser: return CEFPaneKey(pane: pane, profile: .default)
        case .pages: return pagesProfile.map { CEFPaneKey(pane: pane, profile: $0, offTheRecord: true) }
        }
    }
}

extension CEFEngine {
    /// Memory pressure above normal holds Chromium's spare windows (`ChromiumWarmup`'s memory
    /// consumer): none is made or given back until `false`; the untaken ones stay.
    public func holdSpareWindows(_ held: Bool) {
        CEFRuntime.shared.spareWindow.setHeld(held)
    }

    /// Critical memory pressure closes Chromium's untaken spare windows (`ChromiumWarmup`'s memory
    /// consumer), and so does `debug.cef drop_spare` (what the spares cost); a tab parked in one moves
    /// to a shown pane.
    public func closeUntakenSpareWindows() {
        CEFRuntime.shared.spareWindow.drop(runtime: .shared)
    }

    /// How many untaken spare Chromium windows are up or being built (the warmup's memory report).
    public var spareWindowCount: Int { CEFRuntime.shared.spareWindow.untakenCount }
}

extension CEFPaneHost {
    /// True while this host is an untaken spare window.
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
            self.placeholder = nil
            // The joined tab is what this host shows: Chromium's activation
            // after the close is this host's own, never a foreign one.
            if let browser = tab.browserID { self.lastActivated = browser }
            self.removed(blank)
            blank.close()
            for parked in self.runtime.spareWindow.takeParked(for: self.key)
            where self.runtime.tabsByBrowser[parked.browser] == nil && !self.runtime.orphans.ledger.isClosed(parked.browser) {
                self.adoptChromiumTab(browser: parked.browser, disposition: parked.disposition, bounds: parked.bounds)
            }
        }
    }
}
