/// What a pairing link asks for.
public enum PairingLinkKind: Hashable, Sendable {
    /// A QR offer from a Mac: claim it with the bound host key.
    case pair(PairingOffer)
    /// Open a host this account already trusts.
    case attach(host: String, team: String)
}
