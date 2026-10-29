import Foundation

/// Host mode: a pane's first window waits for the Chromium Host's verdict on its browser profile's
/// proxy (#24432). In process the shim answers in `ensureCreated`'s call; the
/// host answers in a REPLY, and the window state says the pane is waiting
/// (`WindowState.awaitingProfileProxy`), so a tab or a popup placeholder that asks meanwhile joins the
/// wait as it joins a window being built.
extension CEFPaneHost {
    /// `tab`, and every tab that asks meanwhile, waits for the host's verdict on the profile's proxy.
    func awaitProfileProxy(first tab: CEFTab) {
        tab.isCreationPending = true
        window = .awaitingProfileProxy
        runtime.whenProfileProxyApplied(key.profile) { [weak self] applied in
            // Out of the REPLY's delivery, as recreateWindow runs out of OnAfterCreated.
            self?.endOfTurn { [weak self] in self?.profileProxyDecided(applied) }
        }
    }

    /// Applied: the window is asked for, the shown tab first, as after a late window. Refused, failed
    /// or past its reply deadline: the waiting tabs fail (fail closed, as in process).
    func profileProxyDecided(_ applied: Bool) {
        // Every tab closed meanwhile (`removed` reset the window): nothing waits.
        guard case .awaitingProfileProxy = window else { return }
        window = .none
        let waiting = tabs.filter { $0.browserID == nil && $0.isCreationPending }
        for tab in waiting { tab.isCreationPending = false }
        guard applied else {
            for tab in waiting where !tab.isClosed { tab.creationFailed() }
            return
        }
        recreateWindow(for: waiting)
    }
}
