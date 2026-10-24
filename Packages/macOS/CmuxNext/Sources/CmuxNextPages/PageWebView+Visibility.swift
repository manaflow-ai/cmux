public import AppKit
public import CmuxNextDesign

/// Whether anybody can see the page, for its router (``PageRouter/isPageHidden``): a page out of a
/// window, hidden (another tab took the pane, a hidden workspace), parked (an alpha-parked
/// workspace, ``ParkingContainer``; the pool's parked spare) or in a covered or minimized window.
/// The drawing rule is ``WindowDrawPolicy``'s, the one every native surface uses (automation
/// launches keep a covered window's content live). The window's occlusion comes from its
/// ``WindowOcclusionFamily``, one observation per window. Either engine: the router feeds WebKit
/// and Chromium pages alike.
extension PageWebView: ParkingObserver {
    /// A workspace above it parked or came back without hiding.
    public func parkingDidChange() {
        updatePageVisibility()
    }

    /// Tells the router whether nobody can see the page now.
    func updatePageVisibility() {
        let hidden = isParkedSpare || !WindowDrawPolicy.inputs(for: self, suspended: false).draws
        if router.isPageHidden != hidden { router.isPageHidden = hidden }
    }

    /// Follows the occlusion of the window the page is in now (none out of a window), leaving
    /// `previous`'s.
    func followWindowVisibility(leaving previous: NSWindow?) {
        if let previous, previous !== window { WindowOcclusionFamily.of(previous).unfollow(self) }
        if let window {
            WindowOcclusionFamily.of(window).follow(self) { [weak self] _ in self?.updatePageVisibility() }
        }
        updatePageVisibility()
    }

    /// Stops following its window's occlusion (the page closed).
    func endWindowVisibility() {
        if let window { WindowOcclusionFamily.of(window).unfollow(self) }
    }
}
