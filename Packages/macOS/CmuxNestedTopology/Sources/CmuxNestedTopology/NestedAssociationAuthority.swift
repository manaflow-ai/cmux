/// Provenance for a pane-to-parent association.
public enum NestedAssociationAuthority: String, Codable, Sendable {
    /// Parentage came from an authoritative provider snapshot or event.
    case provider

    /// Parentage came from a one-shot prompt or environment heuristic.
    case heuristic
}
