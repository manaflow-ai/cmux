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

    /// Extensions or their actions changed: refresh the profile mirrors of
    /// the window's tabs (a pin changes both lists).
    func refreshExtensionStores(window: Int32, browser: Int32) {
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
    /// pane; a window cmux does not host (chrome.windows.create, a tab opened
    /// with no window) has its tab moved into the most recently shown pane.
    func adoptOrphan(browser: Int32, window: Int32) {
        guard !adoptions.isClosed(browser) else { return }
        if let host = hosts.values.first(where: { $0.owns(window: window) || $0.containsBrowser(inWindow: window) }) {
            host.adoptChromiumTab(browser: browser)
            return
        }
        if hosts.values.contains(where: \.isCreatingWindow) {
            adoptions.wait(Orphan(browser: browser, window: window))
            return
        }
        moveIntoShownPane(browser: browser)
    }

    /// A pane's window now exists: adopt the tabs that were created in it
    /// before its first browser reported.
    func windowBecameLive(_ host: CEFPaneHost) {
        let waiting = adoptions.takeWaiting()
        for orphan in waiting {
            if host.owns(window: orphan.window) {
                host.adoptChromiumTab(browser: orphan.browser)
            } else if hosts.values.contains(where: \.isCreatingWindow) {
                adoptions.wait(orphan)
            } else {
                moveIntoShownPane(browser: orphan.browser)
            }
        }
    }

    /// Runs on the next main-actor turn: this is reached from
    /// OnAfterCreated, inside Chromium's tab insertion, where moving the tab
    /// to another tab strip would re-enter it.
    private func moveIntoShownPane(browser: Int32) {
        Task { @MainActor [weak self] in self?.moveIntoShownPaneNow(browser: browser) }
    }

    private func moveIntoShownPaneNow(browser: Int32) {
        // Chromium may have closed it meanwhile (a tab an extension opened
        // and removed at once): adopting it would leave a ghost tab.
        guard tabsByBrowser[browser] == nil, !adoptions.isClosed(browser) else { return }
        guard let shim, forkAPIVersion >= 3,
              let host = lastShownHost ?? hosts.values.first(where: { $0.isLive }),
              let anchor = host.anchorBrowser,
              shim.tabMoveToWindow(browser, anchor, -1) == 1 else {
            logger.error("CEF browser \(browser) in a window cmux does not host; closing it")
            shim?.close(browser)
            return
        }
        host.adoptChromiumTab(browser: browser)
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
