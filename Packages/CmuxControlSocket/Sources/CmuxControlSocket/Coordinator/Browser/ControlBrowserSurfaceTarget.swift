public import Foundation

/// The pre-parsed target a `browser.*` command uses to resolve its browser
/// surface, mirroring the legacy `v2BrowserWithPanel` inputs: the routing
/// selectors pick the TabManager/Workspace, and the explicit surface/pane ids
/// (parsed by the coordinator from `surface_id`/`tab_id`/`pane_id`, accepting
/// `kind:N` refs) drive the legacy `v2ResolveBrowserSurfaceId` precedence.
public struct ControlBrowserSurfaceTarget: Sendable, Equatable {
    /// The routing selectors for TabManager/Workspace resolution.
    public let routing: ControlRoutingSelectors
    /// The explicit surface target (`surface_id`, then `tab_id`), if any.
    public let surfaceID: UUID?
    /// The explicit `pane_id` target, if any.
    public let paneID: UUID?

    /// Creates a browser surface target.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The explicit surface target, if any.
    ///   - paneID: The explicit pane target, if any.
    public init(routing: ControlRoutingSelectors, surfaceID: UUID?, paneID: UUID?) {
        self.routing = routing
        self.surfaceID = surfaceID
        self.paneID = paneID
    }
}
