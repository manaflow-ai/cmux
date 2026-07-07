/// The axis of a ``CmuxSplitDefinition`` in the declarative layout tree.
public enum CmuxSplitDirection: String, Codable, Sendable, Hashable {
    /// A left/right split.
    case horizontal
    /// A top/bottom split.
    case vertical
}
