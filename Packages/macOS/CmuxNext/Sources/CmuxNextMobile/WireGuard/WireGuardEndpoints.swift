import Darwin
import Foundation

/// The UDP endpoints a phone can try to reach this Mac, best first: LAN
/// IPv4, then tailnet-style CGNAT IPv4 (100.64.0.0/10), then other IPv4,
/// then routable IPv6. Loopback, link-local and down interfaces are skipped.
struct WireGuardEndpoints: Sendable {
    let port: UInt16

    func candidates() -> [String] {
        var ranked: [(rank: Int, endpoint: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("bridge") || name.hasPrefix("anpi") {
                continue
            }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                guard let text = numericHost(address, length: socklen_t(MemoryLayout<sockaddr_in>.size)) else { continue }
                if let rank = Self.rankIPv4(text) { ranked.append((rank, "\(text):\(port)")) }
            case AF_INET6:
                guard let text = numericHost(address, length: socklen_t(MemoryLayout<sockaddr_in6>.size)) else { continue }
                let lower = text.lowercased()
                if lower.hasPrefix("fe80") || lower.contains("%") || lower == "::1" { continue }
                ranked.append((lower.hasPrefix("fd7a:115c") ? 2 : 4, "[\(text)]:\(port)"))
            default:
                continue
            }
        }
        var seen = Set<String>()
        return ranked.sorted { $0.rank < $1.rank }.map(\.endpoint).filter { seen.insert($0).inserted }
    }

    static func rankIPv4(_ text: String) -> Int? {
        let octets = text.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return nil }
        switch (octets[0], octets[1]) {
        case (127, _), (169, 254): return nil
        case (192, 168), (10, _): return 0
        case (172, 16...31): return 0
        case (100, 64...127): return 1
        default: return 3
        }
    }

    private func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
