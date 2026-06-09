import Foundation

/// Compact short-key DTO for ``CmxAttachEndpoint``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
struct CompactAttachEndpoint: Codable {
    let t: String
    let h: String?
    let p: Int?
    let i: String?
    let rh: String?
    let da: [String]?
    let ru: String?
    let u: String?

    init(_ endpoint: CmxAttachEndpoint) {
        switch endpoint {
        case let .hostPort(host, port):
            t = "host_port"
            h = host
            p = port
            i = nil
            rh = nil
            da = nil
            ru = nil
            u = nil
        case let .peer(id, relayHint, directAddrs, relayURL):
            t = "peer"
            h = nil
            p = nil
            i = id
            rh = relayHint
            da = directAddrs.isEmpty ? nil : directAddrs
            ru = relayURL
            u = nil
        case let .url(url):
            t = "url"
            h = nil
            p = nil
            i = nil
            rh = nil
            da = nil
            ru = nil
            u = url
        }
    }

    func endpoint() throws -> CmxAttachEndpoint {
        switch t {
        case "host_port":
            guard let h, let p else {
                throw corruptedEndpoint("host_port endpoint requires h and p")
            }
            return .hostPort(host: h, port: p)
        case "peer":
            guard let i else {
                throw corruptedEndpoint("peer endpoint requires i")
            }
            return .peer(id: i, relayHint: rh, directAddrs: da ?? [], relayURL: ru)
        case "url":
            guard let u else {
                throw corruptedEndpoint("url endpoint requires u")
            }
            return .url(u)
        default:
            throw corruptedEndpoint("Unknown attach endpoint type: \(t)")
        }
    }
}

private func corruptedEndpoint(_ message: String) -> DecodingError {
    DecodingError.dataCorrupted(DecodingError.Context(
        codingPath: [],
        debugDescription: message
    ))
}
