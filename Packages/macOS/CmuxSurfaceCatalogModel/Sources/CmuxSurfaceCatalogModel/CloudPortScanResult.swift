import Foundation

/// A successful listener inventory classified for the browser proxy's guest IPv4 loopback route.
public struct CloudPortScanResult: Equatable, Sendable {
    public let ports: [Int]
    public let loopbackOnlyPorts: [Int]
    public let otherBindingPorts: [Int]

    public init(ports: [Int], loopbackOnlyPorts: [Int] = [], otherBindingPorts: [Int] = []) {
        self.ports = ports
        self.loopbackOnlyPorts = loopbackOnlyPorts
        self.otherBindingPorts = otherBindingPorts
    }

    public init?(socketListing: String) {
        var applicationListings: [String] = []
        var socketRows = 0
        var diagnosticRows = 0
        for line in socketListing.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("State ") || text.hasPrefix("Proto ") || text.hasPrefix("Active Internet") { continue }
            // `ss` may include non-listening rows (for example an UNCONN
            // socket or a diagnostic line) alongside the listeners. Those
            // rows do not invalidate the successful listener inventory.
            let fields = text.split(whereSeparator: { $0.isWhitespace })
            guard fields.contains("LISTEN") else {
                if Self.isSocketRow(fields) { socketRows += 1 } else { diagnosticRows += 1 }
                continue
            }
            guard !CmuxTuiSnapshotParser.listeningPortBindings(fromSocketListing: text).isEmpty else {
                diagnosticRows += 1
                continue
            }
            socketRows += 1
            if !Self.isContainerRuntimeListener(text) {
                applicationListings.append(text)
            }
        }
        // Diagnostics beside real socket rows are noise; diagnostics alone
        // mean the inventory itself failed, not that nothing is listening.
        if socketRows == 0 && diagnosticRows > 0 { return nil }
        let bindings = CmuxTuiSnapshotParser.listeningPortBindings(fromSocketListing: applicationListings.joined(separator: "\n"))
            .filter { !CmuxTuiSnapshotParser.internalPorts.contains($0.port) }
        var reachable = Set<Int>()
        var wildcard = Set<Int>()
        var other = Set<Int>()
        for binding in bindings {
            // `ss` suffixes device-bound listeners with a zone, e.g. `127.0.0.53%lo`.
            let bracketless = binding.address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            let address = bracketless.split(separator: "%", maxSplits: 1).first.map(String.init) ?? bracketless
            if ["0.0.0.0", "*", "::", "::ffff:0.0.0.0"].contains(address) {
                reachable.insert(binding.port)
                wildcard.insert(binding.port)
            } else if ["127.0.0.1", "::ffff:127.0.0.1", "localhost"].contains(address) {
                reachable.insert(binding.port)
            } else if !address.hasPrefix("127."), !address.hasPrefix("::ffff:127.") {
                // Other 127/8 aliases are system stubs (systemd-resolved on 127.0.0.53/54),
                // not user services the route could reach by rebinding.
                other.insert(binding.port)
            }
        }
        ports = reachable.sorted()
        loopbackOnlyPorts = reachable.subtracting(wildcard).sorted()
        otherBindingPorts = other.subtracting(reachable).sorted()
    }

    /// An `ss` row in another socket state, or a `netstat` protocol row.
    private static func isSocketRow(_ fields: [Substring]) -> Bool {
        guard let first = fields.first?.uppercased() else { return false }
        return socketStates.contains(first) || first.hasPrefix("TCP") || first.hasPrefix("UDP")
    }

    private static let socketStates: Set<String> = [
        "UNCONN", "ESTAB", "SYN-SENT", "SYN-RECV", "FIN-WAIT-1", "FIN-WAIT-2",
        "TIME-WAIT", "CLOSE-WAIT", "LAST-ACK", "CLOSING", "CLOSED",
    ]

    /// Runtime management APIs choose ephemeral ports; their owner, not the port number,
    /// distinguishes them from an application. Missing ownership never hides a listener.
    private static func isContainerRuntimeListener(_ line: String) -> Bool {
        let owners: [String]
        if let start = line.range(of: "users:((") {
            owners = line[start.lowerBound...].components(separatedBy: "(\"").dropFirst().compactMap {
                guard let end = $0.firstIndex(of: "\"") else { return nil }
                return String($0[..<end])
            }
        } else if let field = line.split(whereSeparator: { $0.isWhitespace }).last,
                  let slash = field.firstIndex(of: "/"), Int(field[..<slash]) != nil {
            owners = [String(field[field.index(after: slash)...])]
        } else {
            owners = []
        }
        return !owners.isEmpty && owners.allSatisfy { $0 == "containerd" || $0 == "dockerd" }
    }

    public var state: CloudPortDiscoveryState {
        guard !ports.isEmpty else {
            return .empty(otherBindingPorts.isEmpty ? .noListeningService : .otherInterfaceOnly)
        }
        return ports.count == loopbackOnlyPorts.count ? .loopbackOnly : .available
    }
}
