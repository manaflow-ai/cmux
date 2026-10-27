import AppKit
public import CmuxNextDesign

/// The list's clip (the ``ScrollGeometryClipView`` the edge fade and scroll fit share) pushes its
/// scrolls and resizes here, as Chromium's `views::ScrollView` runs its contents-scrolled callbacks
/// from `OnScrolled` (ui/views/controls/scroll_view.cc): no NotificationCenter observer.
extension SidebarView: ScrollGeometryClient {
    /// A scroll realizes the rows it shows; a new clip size refits the list (which realizes them too).
    /// A document resize alone is the list's own and needs neither.
    public func scrollGeometryDidChange(_ change: ScrollGeometryChange) {
        let clipSize = scrollView.contentView.bounds.size
        if change.contains(.resized), clipSize != fittedClipSize {
            fittedClipSize = clipSize
            syncListSize()
        }
        // The list updates row hover as rows move. A window-wide refresh here would rescan every
        // chrome target on every scroll tick and adds no state change for the sidebar's fixed chrome.
        if change.contains(.scrolled) { list.realizeVisibleRows() }
    }
}
