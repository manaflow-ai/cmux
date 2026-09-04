import Foundation

/// Runtime ownership and focus behavior for a right-sidebar panel.
///
/// A descriptor must choose one behavior, so focus routing and workspace-root
/// synchronization stay data-driven when a new panel is registered instead of
/// relying on mode-name switches scattered across controllers.
enum RightSidebarPanelBehavior: Equatable, Sendable {
    case fileExplorerOutline
    case fileExplorerSearch
    case sessionIndex
    case feed
    case dock
    case sourceControl
    case host
    case none
}
