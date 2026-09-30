import AppKit
import Foundation

extension CEFRuntime {
    /// The extension mirror of `profile` (created on first use).
    func extensionStore(for profile: BrowserProfileID) -> BrowserExtensionStore {
        if let store = extensionStores[profile] { return store }
        let store = BrowserExtensionStore(profile: profile, backend: CEFExtensionBackend(runtime: self, profile: profile))
        extensionStores[profile] = store
        return store
    }

    func hasExtensionStore(for profile: BrowserProfileID) -> Bool { extensionStores[profile] != nil }

    /// Extensions or their actions changed: refresh the profile mirrors of
    /// the window's tabs (a pin changes both lists).
    func refreshExtensionStores(window: Int32, browser: Int32) {
        omniboxKeywords.invalidate()
        var profiles: Set<BrowserProfileID> = []
        if let tab = tabsByBrowser[browser] { profiles.insert(tab.profileID) }
        for host in hosts.values where host.owns(window: window) { profiles.insert(host.key.profile) }
        if profiles.isEmpty { profiles = Set(extensionStores.keys) }
        for profile in profiles { extensionStores[profile]?.refresh() }
    }

    // MARK: Tabs Chromium creates

    /// A browser Chromium created itself (target=_blank, window.open,
    /// chrome.tabs.create, an options page) in `window`. When that window is
    /// being created for a pane (extensions open welcome tabs as soon as the
    /// first window exists, before its OnAfterCreated), the tab waits for the
    /// pane. A tab in no window yet (a popup Chromium still places) or in a
    /// window cmux does not host waits for the fork to insert it into a pane
    /// window (fork API 8: `placeUnplaced`); older forks give it a Chromium
    /// window of its own, and the tab moves into the most recently shown
    /// pane (the window guard hides that window).
    func adoptOrphan(browser: Int32, window: Int32, created: CEFCreatedBy = .none) {
        // A popup window's tab may already belong to its popup host (fork API 11).
        guard !adoptions.isClosed(browser), tabsByBrowser[browser] == nil else { return }
        let disposition = created.disposition.tabDisposition ?? .foregroundTab
        if let host = hosts.values.first(where: { $0.owns(window: window) }) {
            let placement = takePlacement(window: window, fallback: disposition, created: created)
            host.adoptChromiumTab(browser: browser, disposition: placement.disposition, bounds: placement.bounds)
            return
        }
        if hosts.values.contains(where: \.isCreatingWindow) {
            adoptions.enqueue(Orphan(browser: browser, window: window))
            return
        }
        if forkAPIVersion >= 8 {
            unplaced[browser] = created
            return
        }
        // The opener's pane (a popup, a link); else the last shown pane.
        moveIntoShownPane(browser: browser, disposition: disposition, preferred: tabsByBrowser[created.opener]?.host)
    }

    /// The fork inserted `browser` into `window` (fork API 8): a tab that
    /// waited for a pane window is adopted there.
    func placeUnplaced(browser: Int32, window: Int32) {
        guard let created = unplaced[browser], tabsByBrowser[browser] == nil,
              let host = hosts.values.first(where: { $0.owns(window: window) }) else { return }
        unplaced[browser] = nil
        let placement = takePlacement(window: window, fallback: created.disposition.tabDisposition ?? .foregroundTab,
                                      created: created)
        // The event arrives inside Chromium's tab strip notification, which
        // forbids tab strip changes (the host may select the new tab): adopt
        // on the next main-actor turn.
        Task { @MainActor [weak self, weak host] in
            guard let self, let host, self.tabsByBrowser[browser] == nil, !self.adoptions.isClosed(browser) else { return }
            host.adoptChromiumTab(browser: browser, disposition: placement.disposition, bounds: placement.bounds)
        }
    }

    /// A pane's window now exists: adopt the tabs that were created in it
    /// before its first browser reported.
    func windowBecameLive(_ host: CEFPaneHost) {
        let waiting = adoptions.takeWaiting()
        for orphan in waiting {
            if host.owns(window: orphan.window) {
                let placement = takePlacement(window: orphan.window, fallback: .foregroundTab)
                host.adoptChromiumTab(browser: orphan.browser, disposition: placement.disposition, bounds: placement.bounds)
            } else if hosts.values.contains(where: \.isCreatingWindow) {
                adoptions.enqueue(orphan)
            } else if forkAPIVersion >= 8 {
                unplaced[orphan.browser] = CEFCreatedBy.none
            } else {
                moveIntoShownPane(browser: orphan.browser, disposition: .foregroundTab)
            }
        }
    }

    /// Runs on the next main-actor turn: this is reached from
    /// OnAfterCreated, inside Chromium's tab insertion, where moving the tab
    /// to another tab strip would re-enter it.
    private func moveIntoShownPane(browser: Int32, disposition: BrowserNewTabDisposition, preferred: CEFPaneHost? = nil) {
        Task { @MainActor [weak self, weak preferred] in
            self?.moveIntoShownPaneNow(browser: browser, disposition: disposition, preferred: preferred)
        }
    }

    private func moveIntoShownPaneNow(browser: Int32, disposition: BrowserNewTabDisposition, preferred: CEFPaneHost?) {
        // Chromium may have closed it meanwhile (a tab an extension opened
        // and removed at once): adopting it would leave a ghost tab.
        guard tabsByBrowser[browser] == nil, !adoptions.isClosed(browser) else { return }
        guard let shim, forkAPIVersion >= 3,
              let host = preferred.flatMap({ $0.isLive ? $0 : nil }) ?? lastShownHost ?? hosts.values.first(where: { $0.isLive }),
              let anchor = host.anchorBrowser,
              shim.tabMoveToWindow(browser, anchor, -1) == 1 else {
            logger.error("CEF browser \(browser) in a window cmux does not host; closing it")
            shim?.close(browser)
            return
        }
        host.adoptChromiumTab(browser: browser, disposition: disposition)
    }

    // MARK: Context menus

    func showContextMenu(browser: Int32, token: Int32, x: Int, y: Int, itemsJSON: String, paramsJSON: String) {
        guard let tab = tabsByBrowser[browser] else {
            shim?.contextMenuDone(token, -1, 0)
            return
        }
        let request = BrowserContextMenuRequest(
            items: BrowserContextMenuItem.decodeList(itemsJSON),
            target: BrowserContextMenuTarget.decode(paramsJSON),
            location: CGPoint(x: x, y: y)
        ) { [weak self] id in
            self?.shim?.contextMenuDone(token, Int32(id ?? -1), 0)
        }
        if tab.delegate == nil {
            BrowserContextMenuBuilder.present(request, in: tab.contentView)
        } else {
            tab.emit(.contextMenu(request))
        }
    }
}
