public import Foundation

extension CmxAttachRoute {
    /// The route projected into the `[String: Any]` shape every mobile-host
    /// status and ticket payload uses on the wire.
    ///
    /// Co-located with ``CmxAttachRoute`` (CONVENTIONS s5/s10) so the type and
    /// its wire projection stay in the same package: ``MobileHostServiceStatus``'s
    /// `payload`, the attach ticket store, and the Cloud presence/registry clients
    /// all build their `routes` arrays from this single accessor. Non-`Sendable`
    /// by construction (it carries `NSNull`), so it stays a computed accessor used
    /// at DEBUG/non-boundary call sites rather than a stored field.
    public var mobileHostJSONObject: [String: Any] {
        var endpointPayload: [String: Any] = [:]
        switch endpoint {
        case let .hostPort(host, port):
            endpointPayload = [
                "type": "host_port",
                "host": host,
                "port": port
            ]
        case let .peer(id, relayHint, directAddrs, relayURL):
            endpointPayload = [
                "type": "peer",
                "id": id,
                "relay_hint": relayHint ?? NSNull(),
            ]
            if !directAddrs.isEmpty {
                endpointPayload["direct_addrs"] = directAddrs
            }
            if let relayURL {
                endpointPayload["relay_url"] = relayURL
            }
        case let .url(url):
            endpointPayload = [
                "type": "url",
                "url": url
            ]
        }

        return [
            "id": id,
            "kind": kind.rawValue,
            "endpoint": endpointPayload,
            "priority": priority
        ]
    }
}
