/// A Chromium window made at an idle moment before any Chromium tab needs
/// one, so the first tab joins a live window (`cmux_tab_add`) instead of
/// building one. Building Chromium's first browser window holds the main
/// thread for about 0.8 s in a macOS 26 VM (mostly `-[NSWindow
/// initWithContentRect:]` waiting on the window server; os-smoke,
/// 2026-10-18), which the first tab then showed as a stall.
///
/// The spare is a host of the default profile's own store with an
/// about:blank placeholder, in no pane (its window starts at the hidden-tab
/// viewport). The first pane host the default profile's own store needs
/// takes it (`take`): it is re-keyed to that pane, the pane's tab joins its
/// window, and the placeholder closes (`CEFPaneHost.closeSparePlaceholder`).
/// Another profile, a remote machine's store or an incognito window gets a
/// window of its own as before. At most one spare per process, made only
/// while no Chromium window exists.
final class CEFSpareWindow {
    static let shared = CEFSpareWindow()
    static let panePrefix = "spare-"

    enum State: String {
        case none, creating, live, taken
    }

    private var host: CEFPaneHost?
    private var made = false
    private(set) var tookAt: ContinuousClock.Instant?

    var state: State {
        if let host { return host.isLive ? .live : .creating }
        return made ? .taken : .none
    }

    /// Starts the spare window: true when it started. Chromium must run and
    /// no Chromium window may exist or be on its way.
    @discardableResult
    func prepare(runtime: CEFRuntime) -> Bool {
        guard !made, runtime.state == .ready,
              !runtime.hosts.values.contains(where: { $0.isLive || $0.isCreatingWindow }) else { return false }
        made = true
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: Self.panePrefix + BrowserTabID.random().rawValue), profile: .default)
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
              spare.isLive || spare.isCreatingWindow else { return nil }
        host = nil
        tookAt = .now
        runtime.hosts[spare.key] = nil
        spare.rekey(key)
        runtime.hosts[key] = spare
        return spare
    }
}

extension CEFPaneHost {
    /// A spare window's host becomes pane `key`'s (same profile and store).
    func rekey(_ key: CEFPaneKey) {
        precondition(key.profile == self.key.profile && key.machineKey == self.key.machineKey && key.offTheRecord == self.key.offTheRecord,
                     "a spare Chromium window keeps its store")
        self.key = key
    }

    /// `tab` joined this window: a spare window's about:blank placeholder
    /// closes (a popup host closes its own in `movePopupsIn`).
    func closeSparePlaceholder(joined tab: CEFTab) {
        guard !isPopupHost, let blank = placeholder, blank !== tab, tab.browserID != nil else { return }
        placeholder = nil
        blank.close()
    }
}
