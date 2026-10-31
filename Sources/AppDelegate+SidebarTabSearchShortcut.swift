import AppKit

extension AppDelegate {
    /// Routes the `searchTabs` shortcut (⌥⌘P by default) to the sidebar
    /// tab-search field of a single window.
    ///
    /// The focus request carries the target window as its notification
    /// `object`; each ``SidebarTabSearchView`` ignores requests for other
    /// windows, so the shortcut never focuses every window's field at once.
    /// - Returns: `true` when the event matched the shortcut and was consumed.
    func handleSidebarTabSearchShortcut(_ event: NSEvent) -> Bool {
        guard matchConfiguredShortcut(event: event, action: .searchTabs) else { return false }
        if let targetWindow = event.window ?? shortcutRoutingActiveWindow {
            NotificationCenter.default.post(name: .cmuxSidebarTabSearchFocusRequested, object: targetWindow)
        }
        return true
    }
}
