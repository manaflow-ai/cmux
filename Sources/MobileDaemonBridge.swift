import Darwin
import Foundation

enum CmuxMobileWebSocketPortResolver {
    static func resolvePort(
        environment: [String: String],
        bundle: Bundle,
        fallbackSeed: String
    ) -> Int {
        if let explicit = Int(environment["CMUX_MOBILE_WS_PORT"] ?? "") {
            return explicit
        }

        if let tag = environment["CMUX_TAG"] ?? environment["CMUX_LAUNCH_TAG"],
           !tag.isEmpty {
            return firstAvailablePort(seed: tag)
        }

        if let bundleIdentifier = bundle.bundleIdentifier {
            for prefix in ["com.cmuxterm.app.debug", "dev.cmux.app.dev"] {
                if bundleIdentifier.count > prefix.count,
                   bundleIdentifier.hasPrefix(prefix) {
                    let suffix = String(bundleIdentifier.dropFirst(prefix.count + 1))
                    if !suffix.isEmpty {
                        return firstAvailablePort(seed: suffix)
                    }
                }
            }
        }

        return firstAvailablePort(seed: fallbackSeed)
    }

    private static func firstAvailablePort(seed: String) -> Int {
        let candidates = portCandidates(seed: seed)
        return candidates.first(where: isTCPPortAvailable) ?? candidates.first ?? 52100
    }

    private static func portCandidates(seed: String) -> [Int] {
        let count = 99
        let start = stableFNV1a(seed) % count
        var ports: [Int] = []
        ports.reserveCapacity(count + 1)
        for offset in 0..<count {
            ports.append(52101 + ((start + offset) % count))
        }
        ports.append(52100)
        return ports
    }

    private static func isTCPPortAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: 0)
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private static func stableFNV1a(_ value: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return Int(hash)
    }
}
