import AppKit

/// An app section view with chrome that shows only while the pointer is over
/// the sidebar, like the titlebar row's buttons (`SidebarView.setChromeRevealed`).
/// The band that hosts the view passes the sidebar's reveal state on.
@MainActor
protocol SidebarHoverRevealing: AnyObject {
    func setHoverRevealed(_ revealed: Bool)
    /// A share of the sidebar's height the section takes (expanded All chats: a third, the list
    /// scrolling inside), nil for its own preferred height.
    var sidebarShare: CGFloat? { get }
}
