public import CMUXMobileCore

extension CmxAttachEndpoint {
    /// A compact, log-safe description of the endpoint for diagnostics.
    public var logDescription: String {
        switch self {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .peer(identity, pathHints):
            let directAddressCount = pathHints.count { $0.kind == .directAddress }
            let addressSummary = directAddressCount == 0
                ? "no-direct-addrs"
                : "\(directAddressCount)-direct-addrs"
            let relay = pathHints.first {
                $0.kind == .relayIdentifier || $0.kind == .relayURL
            }?.value
            return "peer:\(identity.endpointID):\(relay ?? "no-relay"):\(addressSummary)"
        case let .url(url):
            return url
        }
    }
}
