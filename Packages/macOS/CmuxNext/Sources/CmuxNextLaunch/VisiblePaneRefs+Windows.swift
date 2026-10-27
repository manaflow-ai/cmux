public import AppKit
import CmuxNextWakeups

extension VisiblePaneRefs {
    /// Reads the visible panes again when one of `windows` is occluded or shown (its
    /// ``WindowOcclusionFamily``), minimized or restored, or closes (none of which is observable), until
    /// no ref is held. One observer per window and name (``WindowEvents``), like Chromium's one NSWindow
    /// delegate per window.
    ///
    /// - Parameters:
    ///   - windows: The launch's windows.
    ///   - center: Where the windows post (tests pass their own; ``WindowEvents/of(_:center:)`` keeps the first).
    public func followWindows(_ windows: [NSWindow], center: NotificationCenter = .default) {
        guard isHolding else { return }
        // raw-observer-allow: the WindowEvents subscription recipe R-notif asks for (one observer per window and notice); only the notice's name matches
        let names = [NSWindow.didMiniaturizeNotification,
                     // raw-observer-allow: the WindowEvents subscription recipe R-notif asks for (one observer per window and notice); only the notice's name matches
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]
        windowEvents += windows.flatMap { window in
            names.map { WindowEvents.of(window, center: center).subscribe($0, owner: "VisiblePaneRefs") { [weak self] in self?.noteChange() } }
        }
        occlusionWatches += windows.map { window in
            WindowOcclusionFamily.of(window, events: WindowEvents.of(window, center: center))
                .subscribe(.content, owner: "VisiblePaneRefs") { [weak self] _ in self?.noteChange() }
        }
    }
}

extension VisiblePaneRefs.Window {
    /// A window ordered in and not minimized.
    @MainActor public static func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    /// A pane's view in its window and not hidden: the pane shows. A pane in no window does not.
    @MainActor public static func isOnScreen(_ view: NSView) -> Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }
}
