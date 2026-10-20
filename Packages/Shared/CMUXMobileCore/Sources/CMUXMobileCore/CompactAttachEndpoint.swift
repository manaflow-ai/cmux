import Foundation

/// Compact short-key DTO for ``CmxAttachEndpoint``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
///
/// The endpoint type is implied by which keys are present (`u` url, `i` peer,
/// `h`+`p` host/port), so new payloads omit `t`. Payloads from the first
/// compact revision still spell `t` out; when present it is authoritative, so
/// those payloads keep decoding unchanged.
struct CompactAttachEndpoint: Codable {
    let t: String?
    let h: String?
    let p: Int?
    let i: String?
    let rh: String?
    let da: [String]?
    let ru: String?
    let ph: [CmxIrohPathHint]?
    let u: String?

    init(_ endpoint: CmxAttachEndpoint) {
        t = nil
        switch endpoint {
        case let .hostPort(host, port):
            h = host
            p = port
            i = nil
            rh = nil
            da = nil
            ru = nil
            ph = nil
            u = nil
        case let .peer(identity, _):
            h = nil
            p = nil
            i = identity.endpointID
            // A scannable payload discloses Iroh identity only. Managed relays
            // are app configuration, online discovery is authenticated, and
            // first-time offline pairing resolves this EndpointID locally.
            rh = nil
            da = nil
            ru = nil
            ph = nil
            u = nil
        case let .url(url):
            h = nil
            p = nil
            i = nil
            rh = nil
            da = nil
            ru = nil
            ph = nil
            u = url
        }
    }

    func endpoint() throws -> CmxAttachEndpoint {
        switch try resolvedType() {
        case "host_port":
            guard let h, let p else {
                throw Self.corruptedEndpoint("host_port endpoint requires h and p")
            }
            return .hostPort(host: h, port: p)
        case "peer":
            guard let i else {
                throw Self.corruptedEndpoint("peer endpoint requires i")
            }
            if let ph {
                return .peer(
                    identity: try CmxIrohPeerIdentity(endpointID: i),
                    pathHints: ph
                )
            }
            return try .peer(id: i, relayHint: rh, directAddrs: da ?? [], relayURL: ru)
        case "url":
            guard let u else {
                throw Self.corruptedEndpoint("url endpoint requires u")
            }
            return .url(u)
        case let type:
            throw Self.corruptedEndpoint("Unknown attach endpoint type: \(type)")
        }
    }

    /// The explicit `t` when the payload carries one, otherwise the type
    /// implied by which keys are present.
    private func resolvedType() throws -> String {
        if let t {
            return t
        }
        if u != nil {
            return "url"
        }
        if i != nil {
            return "peer"
        }
        if h != nil, p != nil {
            return "host_port"
        }
        throw Self.corruptedEndpoint("Attach endpoint carries no recognizable fields")
    }

    private static func corruptedEndpoint(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: [],
            debugDescription: message
        ))
    }
}
