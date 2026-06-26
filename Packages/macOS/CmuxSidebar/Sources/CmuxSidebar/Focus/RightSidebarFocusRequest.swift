/// A pending request to move keyboard focus into the right sidebar, identified by
/// a monotonically increasing `id` so a later request supersedes an earlier one.
public struct RightSidebarFocusRequest: Equatable {
    /// Monotonic identifier; the owning controller increments a counter per request.
    public let id: UInt64
    /// The right-sidebar mode the request targets.
    public let mode: RightSidebarMode
    /// The endpoint within `mode` that focus should land on.
    public let target: RightSidebarFocusTarget

    /// Creates a focus request.
    /// - Parameters:
    ///   - id: Monotonic identifier from the owning controller's counter.
    ///   - mode: The right-sidebar mode the request targets.
    ///   - target: The endpoint within `mode` that focus should land on.
    public init(id: UInt64, mode: RightSidebarMode, target: RightSidebarFocusTarget) {
        self.id = id
        self.mode = mode
        self.target = target
    }
}
