import AppKit

/// An app section view with chrome that shows only while the pointer is over
/// the sidebar, like the titlebar row's buttons (`SidebarView.setChromeRevealed`).
/// The band that hosts the view passes the sidebar's reveal state on.
@MainActor
protocol SidebarHoverRevealing: AnyObject {
    func setHoverRevealed(_ revealed: Bool)
}
