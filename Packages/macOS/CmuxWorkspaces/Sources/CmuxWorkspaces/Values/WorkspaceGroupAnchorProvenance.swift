/// Records whether the current group anchor was created by cmux or selected
/// from an existing workspace.
public enum WorkspaceGroupAnchorProvenance: String, Codable, Equatable, Sendable {
    /// The anchor was created together with the group and is safe to identify
    /// for explicit anchor-only cleanup.
    case generated
    /// The anchor was selected or promoted from an existing workspace.
    case user
    /// The provenance predates this metadata or could not be established.
    case unknown
}
