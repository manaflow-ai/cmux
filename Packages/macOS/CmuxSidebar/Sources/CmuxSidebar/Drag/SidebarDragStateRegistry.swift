#if DEBUG
public import Foundation

/// Debug-only registry that exposes the live ``SidebarDragState`` of each mounted
/// sidebar keyed by `windowId`.
///
/// The debug-socket `debug.sidebar.simulate_drag` handler reads from this so
/// external profiling tools (e.g. the `profile-pr` skill driving `xctrace`) can
/// generate deterministic drag-state mutations against the running app without
/// HID synthesis. One instance is owned by the app composition root and injected
/// where windows register their drag state.
@MainActor
public final class SidebarDragStateRegistry {
    private var statesByWindowId: [UUID: SidebarDragState] = [:]

    /// Creates an empty registry with no sidebars registered.
    public init() {}

    /// Records the drag state for a mounted sidebar window.
    public func register(windowId: UUID, dragState: SidebarDragState) {
        statesByWindowId[windowId] = dragState
    }

    /// Removes the drag state for an unmounted sidebar window.
    public func unregister(windowId: UUID) {
        statesByWindowId.removeValue(forKey: windowId)
    }

    /// The live drag state for `windowId`, or `nil` if no sidebar is registered.
    public func state(forWindowId windowId: UUID) -> SidebarDragState? {
        statesByWindowId[windowId]
    }

    /// The window ids of every currently registered sidebar.
    public func registeredWindowIds() -> [UUID] {
        Array(statesByWindowId.keys)
    }
}
#endif
