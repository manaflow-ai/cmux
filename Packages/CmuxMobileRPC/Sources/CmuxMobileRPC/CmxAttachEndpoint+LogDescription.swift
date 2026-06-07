public import CMUXMobileCore

extension CmxAttachEndpoint {
    /// A compact, log-safe description of the endpoint for diagnostics.
    public var logDescription: String {
        switch self {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .peer(id, relayHint, directAddrs, relayURL):
            let addressSummary = directAddrs.isEmpty ? "no-direct-addrs" : "\(directAddrs.count)-direct-addrs"
            return "peer:\(id):\(relayHint ?? relayURL ?? "no-relay"):\(addressSummary)"
        case let .url(url):
            return url
        }
    }
}
