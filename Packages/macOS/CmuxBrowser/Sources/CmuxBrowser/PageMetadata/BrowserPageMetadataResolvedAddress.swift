import Darwin
import Foundation
import Network

/// A numeric endpoint produced by the page-metadata DNS resolver.
struct BrowserPageMetadataResolvedAddress: Hashable, Sendable {
    let family: BrowserPageMetadataAddressFamily
    let bytes: [UInt8]

    var endpointHost: NWEndpoint.Host? {
        switch family {
        case .ipv4:
            guard bytes.count == 4,
                  let address = IPv4Address(bytes.map(String.init).joined(separator: ".")) else {
                return nil
            }
            return .ipv4(address)
        case .ipv6:
            guard bytes.count == 16 else { return nil }
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { buffer in
                buffer.copyBytes(from: bytes)
            }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return withUnsafePointer(to: &address) { pointer in
                guard inet_ntop(AF_INET6, pointer, &output, socklen_t(output.count)) != nil,
                      let address = IPv6Address(String(cString: output)) else {
                    return nil
                }
                return .ipv6(address)
            }
        }
    }
}
