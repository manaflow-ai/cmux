/// A sidebar destination that can relinquish workspace-drag autoscroll.
@MainActor
public protocol SidebarWorkspaceDragAutoscrollOwning: AnyObject {
    /// Stops autoscroll when another sidebar becomes the active destination.
    func relinquishWorkspaceDragAutoscroll()
}
