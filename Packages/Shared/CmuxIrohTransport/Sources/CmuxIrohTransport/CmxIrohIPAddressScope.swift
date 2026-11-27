import Darwin
import Foundation

/// Classifies a socket address without retaining it past initialization.
struct CmxIrohIPAddressScope: Sendable {
    let isPrivate: Bool

    init(socketAddress: String) {
        guard let host = Self.host(from: socketAddress) else {
            isPrivate = false
            return
        }
        let addressLiteral = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host

        var ipv4 = in_addr()
        if addressLiteral.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            let first = UInt8(truncatingIfNeeded: address >> 24)
            let second = UInt8(truncatingIfNeeded: address >> 16)
            isPrivate = first == 10
                || first == 127
                || (first == 100 && (64 ... 127).contains(second))
                || (first == 169 && second == 254)
                || (first == 172 && (16 ... 31).contains(second))
                || (first == 192 && second == 168)
            return
        }

        var ipv6 = in6_addr()
        if addressLiteral.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let isUniqueLocal = bytes[0] & 0xfe == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isMappedIPv4 = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
            if isMappedIPv4 {
                let mapped = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15]):0"
                isPrivate = Self(socketAddress: mapped).isPrivate
            } else {
                isPrivate = isUniqueLocal || isLinkLocal || isLoopback
            }
            return
        }

        isPrivate = false
    }

    private static func host(from socketAddress: String) -> String? {
        if socketAddress.first == "[",
           let closingBracket = socketAddress.firstIndex(of: "]") {
            return String(socketAddress[socketAddress.index(after: socketAddress.startIndex) ..< closingBracket])
        }
        let colonCount = socketAddress.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 1, let colon = socketAddress.lastIndex(of: ":") {
            return String(socketAddress[..<colon])
        }
        return colonCount > 1 ? socketAddress : nil
    }
}
