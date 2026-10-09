public import CmuxLinkDirect

/// B4's `DirectAuthorizer` backed by the trust store: the Mac (B5) passes it
/// to `DirectAcceptor(authorizer:)` with its own host id, so own devices and
/// accepted guests of that host may complete the Noise handshake.
public struct TrustStoreAuthorizer: DirectAuthorizer {
    private let lookup: any TrustedKeyLookup
    private let host: String?

    public init(lookup: any TrustedKeyLookup, host: String?) {
        self.lookup = lookup
        self.host = host
    }

    public func authorize(device: DirectPublicKey) async -> Bool {
        await lookup.isTrustedDevice(directKey: device.rawRepresentation, onHost: host)
    }
}
