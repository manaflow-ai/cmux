/// Git state reported for a remote workspace.
public struct MobileWorkspaceGitState: Decodable, Sendable, Equatable {
    /// The first branch in the host sidebar's spatial display order.
    public let branch: String
    /// Whether that branch's working tree has uncommitted changes.
    public let isDirty: Bool

    private enum CodingKeys: String, CodingKey {
        case branch
        case isDirty = "is_dirty"
    }
}
