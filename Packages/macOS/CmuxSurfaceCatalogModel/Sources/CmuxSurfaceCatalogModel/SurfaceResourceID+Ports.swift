import Foundation

extension CmuxTuiSnapshotParser {
    /// One local socket binding from `ss -ltn` or `netstat -ltn`.
    public struct ListeningPortBinding: Hashable, Sendable {
        public let port: Int
        public let address: String

        /// Loopback-only listeners cannot be reached through a machine's
        /// private network address. A port with any wildcard/non-loopback
        /// binding remains reachable even if another process also binds loopback.
        public var isLoopbackOnly: Bool {
            let normalized = address
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: "%", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
                .map { $0.lowercased() } ?? ""
            if normalized == "localhost" || normalized == "::1" { return true }
            // Linux may print an IPv4 loopback listener as an IPv4-mapped IPv6
            // address (`::ffff:127.0.0.1`). Treat every mapped 127/8 address
            // as loopback before deciding that a private-address preview is
            // reachable.
            if let mappedIPv4 = normalized.split(separator: ":").last,
               mappedIPv4.split(separator: ".").count == 4 {
                let octets = mappedIPv4.split(separator: ".")
                if octets.first == "127" { return true }
            }
            let octets = normalized.split(separator: ".")
            return octets.count == 4 && octets[0] == "127"
        }

        public init(port: Int, address: String) {
            self.port = port
            self.address = address
        }
    }

    /// Parses local address/port pairs while retaining the bind address for
    /// providers that open services directly over a private network.
    public static func listeningPortBindings(fromSocketListing text: String) -> [ListeningPortBinding] {
        var byPort: [Int: Set<String>] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 4 else { continue }
            // `ss`: State Recv-Q Send-Q Local:Port …; `netstat`: Proto Recv-Q
            // Send-Q Local:Port … . The first numeric port in the local prefix
            // is the local endpoint; peer ports are intentionally ignored.
            for column in columns.prefix(5) {
                guard let colon = column.lastIndex(of: ":"),
                      let port = Int(column[column.index(after: colon)...]),
                      (1...65_535).contains(port) else { continue }
                let address = String(column[..<colon])
                byPort[port, default: []].insert(address)
                break
            }
        }
        return byPort
            .flatMap { entry in
                entry.value.map { address in
                    ListeningPortBinding(port: entry.key, address: address)
                }
            }
            .sorted {
                $0.port != $1.port ? $0.port < $1.port : $0.address < $1.address
            }
    }

    /// Whether a listener is reachable through a private machine address.
    /// Kept pure so the provider can apply it before publishing a resource.
    public static func reachableListeningPorts(
        fromSocketListing text: String,
        privateAddress: String?
    ) -> [Int] {
        var loopbackOnlyByPort: [Int: Bool] = [:]
        for binding in listeningPortBindings(fromSocketListing: text) {
            loopbackOnlyByPort[binding.port] =
                (loopbackOnlyByPort[binding.port] ?? true) && binding.isLoopbackOnly
        }
        return loopbackOnlyByPort.keys
            .filter { privateAddress == nil || loopbackOnlyByPort[$0] == false }
            .sorted()
    }
}

extension SurfaceResourceID {
    /// The numeric port encoded by the canonical cloud forwarded-port identity.
    /// Snapshot browser views that visit localhost are normalized to this key so
    /// the machine port and its workspace row share one resource identity.
    public var forwardedPort: Int? {
        guard kind == .browser, key.hasPrefix("port:") else { return nil }
        let value = key.dropFirst("port:".count)
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        guard key == SurfaceResourceID.portKey(port) else { return nil }
        return port
    }

    /// Whether this id is the machine-level forwarded-port resource.
    public var isForwardedPort: Bool { forwardedPort != nil }
}

extension SurfaceResourceID {
    /// The key every provider uses for a machine's one VNC display (T10 makes this a list).
    public static let desktopDisplayKey = "display:1"

    /// The key for the browser that shows a forwarded HTTP port.
    public static func portKey(_ port: Int) -> String { "port:\(port)" }
}
