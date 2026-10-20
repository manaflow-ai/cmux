public import CMUXMobileCore

extension CmxAttachEndpoint {
    /// A compact, log-safe description of the endpoint for diagnostics.
    public var logDescription: String {
        switch self {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .peer(_, pathHints):
            let directAddressCount = pathHints.count { $0.kind == .directAddress }
            let addressSummary = directAddressCount == 0
                ? "no-direct-addrs"
                : "\(directAddressCount)-direct-addrs"
            let relayCount = pathHints.count {
                $0.kind == .relayIdentifier || $0.kind == .relayURL
            }
            let relaySummary = relayCount == 0
                ? "no-relays"
                : "\(relayCount)-relays"
            return "peer:\(relaySummary):\(addressSummary)"
        case let .url(url):
            return url
        }
    }
}
