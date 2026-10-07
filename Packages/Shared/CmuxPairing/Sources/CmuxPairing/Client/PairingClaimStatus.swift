/// The outcome of a claim.
public enum PairingClaimStatus: String, Hashable, Sendable, Codable {
    /// Same account: the host is trusted now.
    case trusted
    /// Another account: waiting for the host owner to accept.
    case pending
}
