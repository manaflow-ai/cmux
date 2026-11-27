public import Foundation

/// The app side's answer to the `system.tree` window walk: the matched window
/// nodes plus the two found-flags the legacy body tracked for its `not_found`
/// errors.
public struct ControlSystemTreeResolution: Sendable, Equatable {
    /// Whether the requested window was seen (always `true` when no specific
    /// window was requested, matching the legacy initial value).
    public let windowFound: Bool
    /// Whether the workspace filter matched (always `true` when no filter was
    /// given, matching the legacy initial value).
    public let workspaceFound: Bool
    /// The window nodes to emit, in enumeration order.
    public let windows: [ControlSystemTreeWindowNode]

    /// Creates a tree resolution.
    ///
    /// - Parameters:
    ///   - windowFound: Whether the requested window was seen.
    ///   - workspaceFound: Whether the workspace filter matched.
    ///   - windows: The window nodes to emit.
    public init(
        windowFound: Bool,
        workspaceFound: Bool,
        windows: [ControlSystemTreeWindowNode]
    ) {
        self.windowFound = windowFound
        self.workspaceFound = workspaceFound
        self.windows = windows
    }
}
