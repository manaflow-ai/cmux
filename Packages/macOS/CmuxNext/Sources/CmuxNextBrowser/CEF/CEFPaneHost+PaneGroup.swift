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
    /// is a popup's, an agent's or a spare's, still waits for a window, or the pane's host shows another tab on screen
    /// (two views of one pane in two windows): the tab then shows from its own window, as before.
    func regroup(_ tab: CEFTab, into pane: BrowserPaneID) {
        guard key.pane != pane, !holdsOwnTab, !isSpare, !tab.awaitsWindowMove, !tab.isCreationPending, !tab.isClosed,
              tabs.contains(where: { $0 === tab }) else { return }
        let target = paneKey(pane)
        guard let paneHost = runtime.hosts[target] else {
            // The first tab of its store the pane shows: its host becomes the pane's, with no Chromium work.
            guard tabs.allSatisfy({ $0 === tab || $0 === placeholder }) else { return }
            lifecycleTrace.record(tab.id, "pane-group rekey pane=\(pane.rawValue)")
            if runtime.hosts[key] === self { runtime.hosts[key] = nil }
            key = target
            runtime.hosts[target] = self
            return
        }
        guard paneHost !== self, !paneHost.holdsOwnTab, !paneHost.isSpare, !paneHost.showsOnScreen(besides: tab) else { return }
        if let browser = tab.browserID {
            guard paneHost.isLive, let anchor = paneHost.anchorBrowser, let shim = runtime.shim else { return }
            #if DEBUG || CMUX_BENCH_HOOKS
            let moved = runtime.benchMarks.span("cef.tab_move") { shim.tabMoveToWindow(browser, anchor, -1) }
            #else
            let moved = shim.tabMoveToWindow(browser, anchor, -1)
            #endif
            guard moved == 1 else {
                runtime.logger.error("CEF tab \(browser) could not move into its pane's window; it keeps its own")
                return
            }
        }
        lifecycleTrace.record(tab.id, "pane-group join pane=\(pane.rawValue) browser=\(tab.browserID.map(String.init) ?? "none")")
        if hostView.superview === tab.container { hostView.removeFromSuperview() }
        removed(tab)
        tab.host = paneHost
        paneHost.add(tab)
        if tab.browserID != nil { paneHost.hostView.layerHosting.windowBrowsersChanged(paneHost.tabs.filter { !$0.awaitsWindowMove }.compactMap(\.browserID)) }
    }

    /// True when this host's view shows a tab other than `tab` in a window, unhidden: reparenting it would take
    /// that page from where it shows.
    func showsOnScreen(besides tab: CEFTab) -> Bool {
        guard let shown = visibleTab, shown !== tab else { return false }
        return shown.container.window != nil && !shown.container.isHiddenOrHasHiddenAncestor
    }
}
