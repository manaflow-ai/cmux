import Foundation

/// Compact short-key DTO for ``CmxAttachEndpoint``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
///
/// The endpoint type is implied by which keys are present (`u` url, `h`+`p`
/// host/port), so new payloads omit `t`. Payloads from the first compact
/// revision still spell `t` out; when present it is authoritative, so those
/// payloads keep decoding unchanged. The removed peer shape (`i` plus hint
/// fields) older Macs still emit is rejected here with a ``DecodingError``;
/// the tolerant route expansion drops such routes instead of failing the
/// whole payload.
struct CompactAttachEndpoint: Codable {
    let t: String?
    let h: String?
    let p: Int?
    let u: String?

    init(_ endpoint: CmxAttachEndpoint) {
        t = nil
        switch endpoint {
        case let .hostPort(host, port):
            h = host
            p = port
            u = nil
        case let .url(url):
            h = nil
            p = nil
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
