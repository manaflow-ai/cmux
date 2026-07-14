/// Identity required to scope a native changes screen.
public struct ChangesWorkspaceContext: Sendable, Equatable {
    /// The iOS workspace row identifier used for local preferences.
    public let workspaceID: String
    /// Optional workspace title for hosting navigation shells.
    public let displayName: String?

    /// Creates workspace context for a changes screen.
    /// - Parameters:
    ///   - workspaceID: Stable workspace identity.
    ///   - displayName: Optional user-facing workspace name.
    public init(workspaceID: String, displayName: String? = nil) {
        self.workspaceID = workspaceID
        self.displayName = displayName
    }
}
