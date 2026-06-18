public import Foundation

/// Which edge of a sidebar row a drop indicator is drawn against.
public enum SidebarDropEdge: Equatable {
    case top
    case bottom
}

/// Where the sidebar should render the drop indicator during a tab/workspace
/// drag: against the `top` or `bottom` edge of the row identified by `tabId`,
/// or at the end of the list when `tabId` is `nil`.
public struct SidebarDropIndicator: Equatable {
    public let tabId: UUID?
    public let edge: SidebarDropEdge

    public init(tabId: UUID?, edge: SidebarDropEdge) {
        self.tabId = tabId
        self.edge = edge
    }
}
