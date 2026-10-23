import AppKit

/// Whether anybody can see the page, for its router (``PageRouter/isPageHidden``): a page out of a
/// window, hidden (another tab took the pane, a hidden workspace) or in a covered or minimized
/// window gets no subscription events until it shows, and then gets them in one script. Each event
/// to a hidden page was a main-thread script evaluation and a render in its web process (#8900).
/// Either engine: the router feeds WebKit and Chromium pages alike.
@MainActor
extension PageWebView {
    /// Tells the router whether nobody can see the page now (never, for a page that does not hold
    /// its events, ``holdsEventsWhileHidden``). Showing it sends the waiting events.
    func updatePageVisibility() {
        let hidden = holdsEventsWhileHidden && Self.nobodySees(self, ignoringOcclusion: Self.ignoresOcclusion)
        if router.isPageHidden != hidden { router.isPageHidden = hidden }
    }

    /// Follows the occlusion of the window the page is in now (none when out of a window). The
    /// observation ends when the page moves to another window, closes (``close()``) or goes away.
    func followWindowOcclusion() {
        endWindowOcclusion()
        if let window {
            occlusionObservation = Task { [weak self, weak window] in
                guard let window else { return }
                for await _ in NotificationCenter.default.notifications(named: NSWindow.didChangeOcclusionStateNotification,
                                                                         object: window) {
                    self?.updatePageVisibility()
                }
            }
        }
        updatePageVisibility()
    }

    /// Stops following the window's occlusion.
    func endWindowOcclusion() {
        occlusionObservation?.cancel()
        occlusionObservation = nil
    }

    /// Whether nobody can see `view`: out of a window, hidden, or (unless `ignoringOcclusion`) its
    /// window covered or minimized. The agent pane's pacer uses the same rule
    /// (`AgentPaneFramePacer.nobodySees`).
    static func nobodySees(_ view: NSView, ignoringOcclusion: Bool) -> Bool {
        guard let window = view.window else { return true }
        if view.isHiddenOrHasHiddenAncestor { return true }
        return !ignoringOcclusion && !window.occlusionState.contains(.visible)
    }

    /// Automation launches keep pages drawing in a covered window (``rendersWhenCovered(_:)``, a
    /// GUI host's windows report occluded), so their pages keep getting events there too.
    /// Read once per process: the launch environment does not change.
    private static let ignoresOcclusion: Bool = {
        #if DEBUG
        rendersWhenCovered(ProcessInfo.processInfo.environment)
        #else
        false
        #endif
    }()
}
