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
        for line in socketListing.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("State ") || text.hasPrefix("Proto ") || text.hasPrefix("Active Internet") { continue }
            guard text.split(whereSeparator: { $0.isWhitespace }).contains("LISTEN"),
                  !CmuxTuiSnapshotParser.listeningPortBindings(fromSocketListing: text).isEmpty else { return nil }
        }
        let bindings = CmuxTuiSnapshotParser.listeningPortBindings(fromSocketListing: socketListing)
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

    public var state: CloudPortDiscoveryState {
        guard !ports.isEmpty else {
            return .empty(otherBindingPorts.isEmpty ? .noListeningService : .otherInterfaceOnly)
        }
        return ports.count == loopbackOnlyPorts.count ? .loopbackOnly : .available
    }
}
