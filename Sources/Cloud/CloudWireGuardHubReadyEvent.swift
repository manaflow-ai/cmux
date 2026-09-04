import Foundation

/// The one JSON line `cmux-tui wg hub` prints the moment its SOCKS5 listener
/// accepts: `{"event":"hub-ready","socket":"<path>","routes":["10.0.0.0/8",…]}`.
///
/// This line is the hub's readiness signal, the same way a `remote connect`
/// sidecar's `connection-snapshot` line names its socket. The `routes` are the
/// tunnel's `AllowedIPs` as the hub sees them, so they are the authoritative
/// membership set for "does this route go through the hub".
struct CloudWireGuardHubReadyEvent: Sendable, Equatable {
    let socketPath: String
    let routes: [String]

    /// Parses one stdout line; nil for any other line the hub prints.
    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["event"] as? String) == "hub-ready",
              let socket = object["socket"] as? String, !socket.isEmpty else {
            return nil
        }
        socketPath = socket
        routes = (object["routes"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Whether a listener currently accepts connections at `socketPath`; the one
    /// sanity check after the hub has announced readiness.
    static func accepts(_ socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
            buffer[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        return result == 0
    }
}
