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

    var state: State {
        guard let host else { return made ? .taken : .none }
        guard host.placeholder != nil else { return .closed }
        return host.isLive ? .live : host.isCreatingWindow ? .creating : .closed
    }

    func isSpare(_ candidate: CEFPaneHost) -> Bool { host === candidate }

    /// Starts the spare window: true when it started. Chromium must run, no
    /// untaken spare may exist, and no other Chromium window may be on its
    /// way (a window built beside another one raced it, os-smoke 2026-10-18).
    @discardableResult
    func prepare(runtime: CEFRuntime) -> Bool {
        guard host == nil, runtime.state == .ready, runtime.acceptsNewBrowsers,
              !runtime.hosts.values.contains(where: \.isCreatingWindow) else { return false }
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
        guard let spare = host, let blank = spare.placeholder else { return }
        host = nil
        spare.placeholder = nil
        spare.removed(blank)
        blank.close()
        runtime.hosts[spare.key] = nil
    }

    /// A Chromium window came up (`CEFPaneHost.windowCreated`): with no spare ready, ask for one,
    /// so a Chromium a tab started, not the warm start, gets a spare too.
    func windowCameUp(_ live: CEFPaneHost) {
        if host == nil, !live.isPopupHost { onNeeded?() }
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
