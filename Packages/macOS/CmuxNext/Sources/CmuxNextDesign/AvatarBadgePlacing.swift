public import AppKit

/// A status view the sidebar's footer may draw as a badge on the profile avatar's corner instead of a line
/// floating above the footer row (app health's `dot` treatment, AppHealthIndicatorView). Either way it takes
/// no room in the row, so its coming and going moves nothing there (SidebarFooterBand.placeHealthIndicator).
@MainActor public protocol AvatarBadgePlacing: NSView {
    var sitsOnAvatar: Bool { get }
}
