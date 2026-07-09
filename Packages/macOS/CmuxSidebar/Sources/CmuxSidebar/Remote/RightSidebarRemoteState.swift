import Foundation

/// The right sidebar's observable state reported by a `getState` command.
public struct RightSidebarRemoteState: Equatable, Sendable {
    /// Whether the right sidebar is currently visible.
    public let visible: Bool
    /// The currently selected right sidebar mode.
    public let mode: RightSidebarMode

    /// Creates a state snapshot.
    public init(visible: Bool, mode: RightSidebarMode) {
        self.visible = visible
        self.mode = mode
    }
}
