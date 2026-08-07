/// Selects which title authorities a snapshot decoder may accept.
public enum NestedTopologySnapshotDecodingMode: Sendable {
    /// Treats decoded nodes as provider input and rejects host/user locks.
    case providerInput

    /// Reconstitutes a snapshot previously published by trusted cmux code.
    case trustedPublishedSnapshot
}
