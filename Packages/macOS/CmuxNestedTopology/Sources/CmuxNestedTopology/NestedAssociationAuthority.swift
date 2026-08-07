/// Provenance for a pane-to-parent association.
public enum NestedAssociationAuthority: String, Codable, Sendable {
    /// Parentage came from an authoritative provider snapshot or event.
    case provider

    /// Parentage came from a successful one-shot prompt or environment association.
    ///
    /// Once accepted, this is a topology-bearing resolved parent rather than a
    /// cosmetic hint. Provider authority may replace it when structured
    /// parentage becomes available.
    case heuristic
}
