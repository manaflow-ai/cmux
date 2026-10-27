import Foundation

/// A profile's first browser tab waits for the profile's built-in extensions (``CEFBuiltInExtensionLoader``,
/// feature `chromiumAdBlockerAtFirstTab`) before it asks for its browser, so its first page loads with
/// them. Both ways a tab gets its browser navigate in the call, so both wait: a pane with no window
/// waits as a whole (`WindowState.awaitingExtensions`), and tabs that ask meanwhile join the wait as they
/// join a window being built; a tab joining a live window (one that took the spare) waits on its own.
extension CEFPaneHost {
    /// Whether `tab`'s browser may be asked for now; false: it waits, pending, and asks again when the
    /// profile's load answered (out of that answer's delivery, as a proxy verdict runs).
    func builtInExtensionsReady(for tab: CEFTab) -> Bool {
        let joinsLiveWindow = isLive
        let ready = runtime.builtInLoader.ready(for: tab, in: self) { [weak self, weak tab] in
            self?.endOfTurn { [weak self, weak tab] in
                guard let self else { return }
                if !joinsLiveWindow {
                    builtInExtensionsLoaded()
                } else if let tab {
                    builtInExtensionsLoaded(joining: tab)
                }
            }
        }
        guard !ready else { return true }
        tab.isCreationPending = true
        if !joinsLiveWindow { window = .awaitingExtensions }
        return false
    }

    /// The pane's window is asked for, the shown tab first, as after a proxy verdict.
    private func builtInExtensionsLoaded() {
        // Every tab closed meanwhile (`removed` reset the window): nothing waits.
        guard case .awaitingExtensions = window else { return }
        window = .none
        let waiting = tabs.filter { $0.browserID == nil && $0.isCreationPending }
        for tab in waiting { tab.isCreationPending = false }
        recreateWindow(for: waiting)
    }

    /// `tab` joins the live window it waited for (or asks for a window, when that one went meanwhile).
    private func builtInExtensionsLoaded(joining tab: CEFTab) {
        guard tab.browserID == nil, tab.isCreationPending, !tab.isClosed, tabs.contains(where: { $0 === tab }) else { return }
        tab.isCreationPending = false
        if ensureCreated(tab), visibleTab === tab, !tab.awaitsWindowMove { showBrowser(of: tab, activate: false) }
    }
}
