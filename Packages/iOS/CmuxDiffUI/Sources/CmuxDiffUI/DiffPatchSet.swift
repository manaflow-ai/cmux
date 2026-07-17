/// Immutable input for a complete changed-file list and diff body.
public struct DiffPatchSet: Sendable, Equatable {
    /// Stable workspace identity used for device-local viewed state.
    public let workspaceID: String
    /// Human-readable base description shown in the summary header.
    public let baseLabel: String
    /// Changed files in display order.
    public let files: [DiffFileSnapshot]

    /// Creates a renderable patch set.
    /// - Parameters:
    ///   - workspaceID: Stable workspace identity.
    ///   - baseLabel: Human-readable base description.
    ///   - files: Changed files in display order.
    public init(workspaceID: String, baseLabel: String, files: [DiffFileSnapshot]) {
        self.workspaceID = workspaceID
        self.baseLabel = baseLabel
        self.files = files
    }
}
