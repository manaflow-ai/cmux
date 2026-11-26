import AppKit
import Foundation

/// A pane's web tabs share one Chromium window (browser.md, Decision 1), so a tab the pane does not show is a
/// background tab of that window: Chromium counts it hidden, its compositor stops, and the fork's freeze applies.
/// The App makes a web tab's page before any pane shows it, so `CEFEngine` keys it to a host of its own; the App
/// names the pane before it shows the tab (`CEFTab.willShow(inPane:)`), and the tab joins the pane's host when its
/// view appears there. A tab with no browser yet (the usual case: a browser is made when its tab first shows) only
/// changes host, and is made as a tab of the pane's window (`tab_add`). One with a browser moves its WebContents into
/// the pane's live window (`cmux_tab_move_to_window`, as popups and agent tabs do), its page kept. A window per tab cost
/// about 30 MB of GPU memory and a compositor for every hidden tab (browser-vs-edge bench, 50 tabs: 1.6 GB of GPU).
extension CEFPaneHost {
    /// The pane id `CEFEngine` gives a web tab no pane named yet: a host of its own until a pane shows it.
    static let ownTabPrefix = "tab-"

    /// A host made for one web tab before a pane showed it: it goes once that tab joins a pane's host.
    var isOwnTabHost: Bool { key.pane.rawValue.hasPrefix(Self.ownTabPrefix) }

    /// The host the App's pane `pane` uses for this host's store (profile, machine store, incognito context).
    func paneKey(_ pane: BrowserPaneID) -> CEFPaneKey {
        CEFPaneKey(pane: pane, profile: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
    }

    /// Moves `tab`, whose view appears in the App's pane `pane`, into that pane's host. Leaves it where it is when it
    /// is a popup's, an agent's or a spare's, or still waits for a window. When the pane's host cannot take it now
    /// (it shows another tab on screen, its window is still being made, the fork refused the move), the tab still
    /// leaves a host whose view shows another tab on screen (`leaveSharedHost`), so two panes never share one view.
    func regroup(_ tab: CEFTab, into pane: BrowserPaneID) {
        guard key.pane != pane, !holdsOwnTab, !isSpare, !tab.awaitsWindowMove, !tab.isCreationPending, !tab.isClosed,
              tabs.contains(where: { $0 === tab }) else { return }
        let target = paneKey(pane)
        // A pane host left with no tab and no window (its tabs closed or hibernated) is as good as none.
        if let stale = runtime.hosts[target], stale !== self, stale.tabs.isEmpty, stale.window == .none, !stale.isSpare,
           !stale.hasLentTabs {
            runtime.hosts[target] = nil
        }
        guard let paneHost = runtime.hosts[target] else {
            if tabs.allSatisfy({ $0 === tab || $0 === placeholder }), !hasLentTabs {
                // The first tab of its store the pane shows: its host becomes the pane's, with no Chromium work.
                lifecycleTrace.record(tab.id, "pane-group rekey pane=\(pane.rawValue)")
                if runtime.hosts[key] === self { runtime.hosts[key] = nil }
                key = target
                runtime.hosts[target] = self
            } else {
                // The tab left a pane with other web tabs (dragged to a split): the new pane gets a host of its own.
                if !move(tab, to: runtime.host(for: target, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)) { leaveSharedHost(tab) }
            }
            return
        }
        guard paneHost !== self, !paneHost.holdsOwnTab, !paneHost.isSpare, !paneHost.showsOnScreen(besides: tab),
              move(tab, to: paneHost) else { return leaveSharedHost(tab) }
    }

    /// Moves `tab` from this host into `destination`: a tab with no browser only changes host; one with a browser
    /// moves into `destination`'s live window, or waits in this host's window for one `destination` makes
    /// (`ensureOwnWindow`), as an agent's background tab does. It waits only while this host keeps other tabs, so
    /// this window is still live to take it back if the fork cannot move it (`returnFromRegroup`). False when it stays.
    @discardableResult
    func move(_ tab: CEFTab, to destination: CEFPaneHost) -> Bool {
        var waits = false
        if let browser = tab.browserID {
            if destination.isLive, let anchor = destination.anchorBrowser, let shim = runtime.shim {
                #if DEBUG || CMUX_BENCH_HOOKS
                let moved = runtime.benchMarks.span("cef.tab_move") { shim.tabMoveToWindow(browser, anchor, -1) }
                #else
                let moved = shim.tabMoveToWindow(browser, anchor, -1)
                #endif
                guard moved == 1 else {
                    runtime.logger.error("CEF tab \(browser) could not move into its pane's window; it keeps its own")
                    return false
                }
            } else if case .creating = destination.window {
                return false
            } else if !tabs.contains(where: { $0 !== tab && $0 !== placeholder && !$0.awaitsWindowMove }) {
                return false
            } else {
                waits = true
            }
        }
        lifecycleTrace.record(tab.id, "pane-group join pane=\(destination.key.pane.rawValue) browser=\(tab.browserID.map(String.init) ?? "none") waits=\(waits)")
        if hostView.superview === tab.container { hostView.removeFromSuperview() }
        removed(tab)
        tab.host = destination
        tab.awaitsWindowMove = waits
        // A tab the fork then cannot move in comes back here rather than close (`CEFPaneHost+Popups`).
        tab.regroupedFrom = waits ? self : nil
        destination.add(tab)
        if tab.browserID != nil, !waits {
            // A spare window the pane took: its blank tab (and spare page) go, as when a tab joins it with `tab_add`.
            destination.closeSparePlaceholder(joined: tab)
            destination.hostView.layerHosting.windowBrowsersChanged(destination.tabs.filter { !$0.awaitsWindowMove }.compactMap(\.browserID))
        }
        return true
    }

    /// The fork could not move `tab` into this host's window (`movePopupsIn`): it goes back to the host it left,
    /// whose window still holds it, and shows from there when that host's view shows no other tab on screen.
    func returnFromRegroup(_ tab: CEFTab, to from: CEFPaneHost) {
        tab.regroupedFrom = nil
        if hostView.superview === tab.container { hostView.removeFromSuperview() }
        removed(tab)
        tab.host = from
        tab.awaitsWindowMove = false
        from.add(tab)
        guard tab.container.window != nil, !tab.container.isHiddenOrHasHiddenAncestor else { return }
        if from.showsOnScreen(besides: tab) {
            runtime.logger.error("CEF tab \(tab.browserID ?? 0) has no window of its own; it shows when its pane's view is free")
            return
        }
        from.present(tab, in: tab.container)
    }

    /// `tab` could not join its pane's host: when this host's view shows another tab on screen, the tab goes to a
    /// host of its own (a window per tab, as before panes shared one), so presenting it never takes that view.
    func leaveSharedHost(_ tab: CEFTab) {
        guard showsOnScreen(besides: tab), !isOwnTabHost else { return }
        let own = paneKey(BrowserPaneID(rawValue: Self.ownTabPrefix + tab.id.rawValue))
        move(tab, to: runtime.host(for: own, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus))
    }

    /// A background tab of this pane an agent drives from its own window points home here (`homeHost`): this host
    /// keeps its key while one does, or the tab would go home to another pane.
    var hasLentTabs: Bool {
        runtime.hosts.values.contains { $0.isAgentHost && $0.tabs.contains { $0.homeHost === self } }
    }

    /// True when this host's view shows a tab other than `tab` in a window, unhidden: reparenting it would take
    /// that page from where it shows.
    func showsOnScreen(besides tab: CEFTab) -> Bool {
        guard let shown = visibleTab, shown !== tab else { return false }
        return shown.container.window != nil && !shown.container.isHiddenOrHasHiddenAncestor
    }
}
