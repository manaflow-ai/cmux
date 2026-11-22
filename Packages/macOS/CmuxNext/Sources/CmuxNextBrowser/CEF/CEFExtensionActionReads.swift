import CmuxNextWakeups

/// Which Chromium tabs read their extension toolbar actions, and when (#32912).
///
/// `cmux_ext_actions` has Chromium draw and PNG-encode every extension icon of one tab on the main
/// thread. Each tab event (a tab inserted or removed, an action changed) used to read it for every
/// tab of the pane: 16-23 ms after each Shift-Cmd-L, 7-16 ms after each DevTools close, growing
/// with the tab count. Chrome's toolbar draws the active tab's actions only and reads a background
/// tab's when it becomes active. Here:
/// - a tab whose actions may have changed reads them at once when it is on screen (its pane shows
///   it and the content lifecycle did not hide it), else it is marked and reads after the frame
///   in which it next shows;
/// - an inserted tab is the only tab whose actions can be new; a removed tab changes no other tab's;
/// - a tab switch reads nothing unless the tab shown was marked.
@MainActor
final class CEFExtensionActionReads {
    /// Tabs whose actions changed while they were not on screen (weak: a closed tab's entry never
    /// matches a new tab at the same address).
    private var stale: [ObjectIdentifier: WeakCEFTab] = [:]
    /// Runs work after the current pass's frame committed (tests pass their own).
    var afterFrame: (@escaping @MainActor () -> Void) -> Void = { AfterFrameCommit().run($0) }

    init() {}

    /// A fork tab event: `tab` is the event's tab, `hosts` the panes that own its window.
    func tabEvent(_ kind: CEFForkTabEvent, tab: CEFTab?, hosts: () -> [CEFPaneHost]) {
        switch kind {
        case .inserted: if let tab { refresh(tab) }
        case .extensionActionsChanged: for host in hosts() { host.tabs.forEach(refresh) }
        default: break
        }
    }

    /// `tab`'s actions may have changed: it reads them now when it is on screen, else when it next shows.
    func refresh(_ tab: CEFTab) {
        guard Self.isShown(tab) else {
            stale[ObjectIdentifier(tab)] = WeakCEFTab(tab)
            return
        }
        stale[ObjectIdentifier(tab)] = nil
        tab.refreshExtensionActions()
    }

    /// A command names `tab` (`browser.extension.run` on a background tab): actions marked stale are read now,
    /// shown or not, so the command sees the tab's current actions.
    func readIfStale(_ tab: CEFTab) {
        guard isStale(tab) else { return }
        stale[ObjectIdentifier(tab)] = nil
        tab.refreshExtensionActions()
    }

    private func isStale(_ tab: CEFTab) -> Bool {
        stale[ObjectIdentifier(tab)]?.tab === tab
    }

    /// `tab` came on screen: a marked tab reads its actions after this frame, so the switch's own frame
    /// waits for no icon encoding.
    func tabShown(_ tab: CEFTab) {
        guard isStale(tab) else { return }
        afterFrame { [weak self, weak tab] in
            guard let self, let tab, Self.isShown(tab), isStale(tab) else { return }
            stale[ObjectIdentifier(tab)] = nil
            tab.refreshExtensionActions()
        }
    }

    static func isShown(_ tab: CEFTab) -> Bool {
        tab.host.visibleTab === tab && !tab.isContentHidden
    }
}
