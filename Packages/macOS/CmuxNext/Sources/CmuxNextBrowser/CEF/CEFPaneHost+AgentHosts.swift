import AppKit
import Foundation

/// Background browser use (user 2026-11-05): an agent drives a Chromium tab its pane does not show. A pane
/// has one Chromium window and only its shown tab has the page window, so a background tab draws no frame
/// and viz runs its animation frames at 1 a second (more than `kUndrawnFrameLimit` undrawn frames). When the
/// App parks such a tab in the agent render window, the tab goes to an agent host of its own: a Chromium
/// window of its own (`cmux_tab_move_to_window` keeps the WebContents, as for popups), whose page window
/// draws in the render window. When its pane shows it again, it goes back to the pane's window.
extension CEFPaneHost {
    static let agentPrefix = "agent-"

    /// A host that holds one background tab of a pane while an agent drives it.
    var isAgentHost: Bool { key.pane.rawValue.hasPrefix(Self.agentPrefix) }

    /// A host that holds a tab of another pane's page in a window of its own (a popup's, an agent's
    /// background tab's): never a pane, a window request's target or a spare.
    var holdsOwnTab: Bool { isPopupHost || isAgentHost }

    /// True when `tab` is a background tab of this pane's window: the pane shows another tab, so
    /// presenting `tab` here would take the page window from the pane.
    func lendsToAgent(_ tab: CEFTab) -> Bool {
        !holdsOwnTab && !isSpare && visibleTab != nil && visibleTab !== tab && !tab.awaitsWindowMove
            && !tab.isCreationPending && !tab.agentWindowRefused && tabs.contains { $0 === tab }
    }

    /// Moves background `tab` to an agent host of its own (same profile and store). A tab with a browser
    /// waits there for that host's window (`ensureOwnWindow`, `movePopupsIn`); one with none creates it.
    func lendToAgent(_ tab: CEFTab) {
        let agentKey = CEFPaneKey(pane: BrowserPaneID(rawValue: Self.agentPrefix + tab.id.rawValue),
                                  profile: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
        let agent = runtime.host(for: agentKey, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)
        lifecycleTrace.record(tab.id, "agent-host lend browser=\(tab.browserID.map(String.init) ?? "none")")
        removed(tab)
        tab.host = agent
        tab.homeHost = self
        tab.awaitsWindowMove = tab.browserID != nil
        agent.add(tab)
    }

    /// The pane shows `tab` again (or the fork could not move it out): it goes back to its pane's host,
    /// into the pane's Chromium window. A tab whose pane has no live window stays here, and the pane shows
    /// it from this host's window.
    func returnHome(_ tab: CEFTab) {
        guard let home = tab.homeHost else { return }
        if !tab.awaitsWindowMove, let browser = tab.browserID {
            guard home.isLive, let anchor = home.anchorBrowser, let shim = runtime.shim,
                  shim.tabMoveToWindow(browser, anchor, -1) == 1 else { return }
        }
        lifecycleTrace.record(tab.id, "agent-host return")
        if hostView.superview === tab.container { hostView.removeFromSuperview() }
        removed(tab)
        tab.host = home
        tab.homeHost = nil
        tab.awaitsWindowMove = false
        // A browser this host's window was still making goes with that window (`lateWindowCreated`).
        if tab.browserID == nil { tab.isCreationPending = false }
        home.add(tab)
        retireIfUnused()
    }

    /// Whether the host view (and so the page window) is hidden while it shows `tab`: when the content
    /// lifecycle hid the page, except in the agent render window. A pane hides its background tabs, and
    /// a parked workspace or minimized window its pages; in the render window that page must draw, or
    /// Chromium runs its animation frames at 1 a second.
    static func hidesHost(_ tab: CEFTab) -> Bool {
        tab.isContentHidden && tab.container.window?.identifier != .agentRenderWindow
    }

    /// Runs `body` (a Chromium window made or a tab moved for an agent host) and gives the keys back to the
    /// window that had them: Chromium makes a new browser window, or one a tab moved into, key, and an agent's
    /// call never moves the person's focus.
    func keepingKey<T>(_ body: () -> T) -> T {
        guard isAgentHost else { return body() }
        let key = NSApp.keyWindow
        let result = body()
        if let key, NSApp.keyWindow !== key, key.isVisible { key.makeKey() }
        return result
    }

    /// An agent host with no tab left but its placeholder: the placeholder closes and the host goes.
    func retireIfUnused() {
        guard isAgentHost, !tabs.contains(where: { !$0.isClosed && $0 !== placeholder }) else { return }
        if let blank = placeholder {
            placeholder = nil
            blank.close()
        }
        hostView.removeFromSuperview()
        if runtime.hosts[key] === self { runtime.hosts[key] = nil }
    }
}
