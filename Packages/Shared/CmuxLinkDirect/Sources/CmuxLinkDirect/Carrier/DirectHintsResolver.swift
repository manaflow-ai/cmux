public import CmuxLink

/// Reads one endpoint from `LinkPeer.hints`: `direct.address`,
/// `direct.port` (optional) and `direct.hostKey` (base64).
public struct DirectHintsResolver: DirectEndpointResolver {
    public let addressKey = "direct.address"
    public let portKey = "direct.port"
    public let hostKeyKey = "direct.hostKey"

    public init() {}

    public func endpoints(for peer: LinkPeer) async -> [DirectEndpoint] {
        endpoint(from: peer.hints).map { [$0] } ?? []
    }

    public func endpoint(from hints: [String: String]) -> DirectEndpoint? {
        guard let text = hints[addressKey], let address = DirectAddress(text),
              let keyText = hints[hostKeyKey], let key = DirectPublicKey(base64: keyText)
        else { return nil }
        let port = hints[portKey].flatMap(UInt16.init) ?? DirectEndpoint.defaultPort
        return DirectEndpoint(address: address, port: port, hostKey: key)
    }

    /// The hints that `endpoint(from:)` reads back.
    public func hints(for endpoint: DirectEndpoint) -> [String: String] {
        guard case let .address(address, port) = endpoint.target else { return [:] }
        return [addressKey: address.host, portKey: String(port), hostKeyKey: endpoint.hostKey.base64]
    }
}
