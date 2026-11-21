/// Rows whose maps share one call (the sidebar row face, `SidebarMapping`): the feed begins it, stages each of its
/// rows the turn maps (``SidebarRowFeed/Make``), runs it once, then finishes each row from its slot.
@MainActor
public protocol SidebarRowBatch: AnyObject {
    /// Empties the batch before its rows stage.
    func begin()
    /// Maps every staged row in one call; false when it could not (each of its rows keeps its last mapped row).
    func run() -> Bool
}
