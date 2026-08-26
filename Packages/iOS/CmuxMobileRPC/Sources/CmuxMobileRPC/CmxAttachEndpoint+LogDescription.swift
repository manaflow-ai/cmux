public import CMUXMobileCore

extension CmxAttachEndpoint {
    /// A compact, log-safe description of the endpoint for diagnostics.
    public var logDescription: String {
        switch self {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .url(url):
            return url
        }
    }
}
