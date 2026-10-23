import Foundation

/// A Chromium window made at an idle moment before any Chromium tab needs
/// one, so the first tab joins a live window (`cmux_tab_add`) instead of
/// building one. Building Chromium's first browser window holds the main
/// thread for about 0.8 s in a macOS 26 VM (mostly `-[NSWindow
/// initWithContentRect:]` waiting on the window server; Tart launch checks,
/// 2026-10-18), which the first tab then showed as a stall.
///
/// The spare is a host of the default profile's own store with an
/// about:blank placeholder, in no pane (its window starts at the hidden-tab
/// viewport). The first host the default profile's own store needs takes it
/// (`take`): it is re-keyed, the tab joins its window, and on the next
/// main-actor turn the placeholder closes (`CEFPaneHost.closeSparePlaceholder`).
/// When that tab closes before the window shows it, the host becomes the
/// spare again (`giveBack`). Another profile, a remote machine's store or an
/// incognito window gets a window of its own as before. At most one spare per
/// process, made only while no Chromium tab exists.
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
    private var made = false
    /// Tabs Chromium created in the spare's window before a tab took it.
    private var parked: [(browser: Int32, disposition: BrowserNewTabDisposition, bounds: CGRect?)] = []

    var state: State {
        guard let host else { return made ? .taken : .none }
        guard host.placeholder != nil else { return .closed }
        return host.isLive ? .live : host.isCreatingWindow ? .creating : .closed
    }

    func isSpare(_ candidate: CEFPaneHost) -> Bool { host === candidate }

    /// Starts the spare window: true when it started. Chromium must run and
    /// no Chromium tab may exist (its window may be on its way).
    @discardableResult
    func prepare(runtime: CEFRuntime) -> Bool {
        guard !made, runtime.state == .ready,
              !runtime.hosts.values.contains(where: { !$0.tabs.isEmpty || $0.isLive || $0.isCreatingWindow }) else { return false }
        made = true
        let key = Self.spareKey()
        let spare = runtime.host(for: key)
        let blank = CEFTab(id: .random(), profile: .default, host: spare, runtime: runtime)
        spare.placeholder = blank
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
        runtime.hosts[spare.key] = nil
        spare.rekey(key)
        runtime.hosts[key] = spare
        return spare
    }

    /// The tab that took `taken` closed before it joined the window, and only
    /// the placeholder is left: `taken` is the spare again.
    func giveBack(_ taken: CEFPaneHost, runtime: CEFRuntime) {
        guard host == nil, taken.placeholder != nil, taken.tabs.count == 1 else { return }
        runtime.hosts[taken.key] = nil
        taken.rekey(Self.spareKey())
        runtime.hosts[taken.key] = taken
        host = taken
        // The pane that showed it is gone: tabs Chromium places must not follow it here.
        if runtime.lastShownHost === taken { runtime.lastShownHost = nil }
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
