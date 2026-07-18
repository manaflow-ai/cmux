/// The direction in which a canonical layout split places its second child.
public enum CanonicalSplitDirection: String, Codable, Equatable, Sendable {
    /// The second child appears to the right of the first child.
    case right

    /// The second child appears below the first child.
    case down
}
