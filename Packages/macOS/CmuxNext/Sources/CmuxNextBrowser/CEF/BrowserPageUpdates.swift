public import AppKit
import CmuxNextCompat

/// The window's page update request: something moved a window's Chromium pages on screen, or changed
/// what clips them, without a frame change of their own views (dividers or the sidebar moved, a clip or
/// corner changed, the window moved). Every page view takes it, whichever way the page draws: a
/// `CEFHostView` re-places the fork's page window (drawn in, or transparent over a hosted page for its
/// input), a host-mode `ChromiumHostPageView` reports its new screen rect, and the cards over a page
/// follow it (`PageFloatingOverlays`). Chrome needs no such request: its page view is an ordinary
/// subview that AppKit moves with its ancestors (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`).
///
/// The window's layout owner sends it through `NSWindow.updateBrowserPageGeometry(force:center:)`; a
/// page view listens through `observe(of:center:_:)` on the center it was given (`.default` in the app,
/// a private one in tests).
nonisolated enum BrowserPageUpdates {
    /// Posted (object: the `NSWindow`) to make every page of that window re-apply its geometry, clip and
    /// occlusion. A page re-applies only when something it reads changed since the fork last read it,
    /// unless `userInfo[forceKey]` is true.
    fileprivate static let name = Notification.Name("CmuxBrowserChildWindowPagesNeedUpdate")
    /// `userInfo` key of `name`: true makes every page re-apply even where nothing it reads changed (a
    /// page window that something other than the fork moved, such as an Accessibility client, goes back
    /// over its host).
    fileprivate static let forceKey = "force"

    /// One page update request: the window it is for and whether every page re-applies.
    struct Update {
        let window: NSWindow?
        let force: Bool
    }

    /// Calls `handler` on each page update request of `window` (nil: of every window) posted on `center`,
    /// until the returned observation is released.
    @MainActor
    static func observe(of window: NSWindow?, center: NotificationCenter,
                        _ handler: @escaping @MainActor (Update) -> Void) -> MainActorObservation {
        MainActorObservation(name, object: window, center: center, read: { note in
            Update(window: note.object as? NSWindow, force: note.userInfo?[forceKey] as? Bool ?? false)
        }, handler)
    }
}

public extension NSWindow {
    /// Asks every Chromium page of this window to re-apply its geometry, clip and occlusion: after the
    /// window's own native overlays over its content moved (`BrowserWindowOcclusionProviding`), a clip
    /// or corner changed with no page move, or the window moved or resized by any means (drag,
    /// Accessibility clients such as Rectangle, display or Space changes, fullscreen, deminiaturize).
    /// A page tells the fork only when what it reads changed since its last read; `force` makes every
    /// page re-apply (a page window moved by another app). `center` is the one the pages were given.
    func updateBrowserPageGeometry(force: Bool = false, center: NotificationCenter = .default) {
        center.post(name: BrowserPageUpdates.name, object: self,
                    userInfo: force ? [BrowserPageUpdates.forceKey: true] : nil)
    }
}
