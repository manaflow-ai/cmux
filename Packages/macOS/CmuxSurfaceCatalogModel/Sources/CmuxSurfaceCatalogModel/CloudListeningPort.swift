import Foundation

/// Why a listener inside a Cloud machine is, or is not, the person's own service.
///
/// `cmux vm ports` and the Ports tab both classify listeners through
/// ``CloudListeningPortKind/classify(port:addresses:processes:displayPortsOwned:)``
/// (through ``CloudListeningPort/inventory(socketListing:displayPortsOwned:)``),
/// so a port hidden in one is hidden in the other.
public enum CloudListeningPortKind: String, Equatable, Sendable, CaseIterable {
    /// A service the person (or their agent) started: a dev server, an API, a database.
    case app
    /// The machine's SSH server.
    case ssh
    /// The resolver stub (systemd-resolved, dnsmasq) on port 53 or 127.0.0.53/54.
    case dns
    /// The cmux-tui daemon and other cmux processes inside the machine.
    case cmux
    /// The VNC server and its noVNC front end behind the Desktop surface.
    case desktop
    /// Container runtime management APIs (containerd, dockerd).
    case container
    /// Listeners baked into the machine image that are never web previews.
    case image

    public var isSystem: Bool { self != .app }
}

/// One TCP port that is listening inside a machine, with its owners.
public struct CloudListeningPort: Equatable, Sendable {
    public let port: Int
    /// Distinct local bind addresses, sorted (`0.0.0.0`, `127.0.0.1`, `[::]`, …).
    public let addresses: [String]
    /// Distinct owning process names, sorted. Empty when the inventory could not see them.
    public let processes: [String]
    /// Distinct owning process ids, sorted. Empty when the inventory could not see them.
    public let pids: [Int]
    public let kind: CloudListeningPortKind

    public init(port: Int, addresses: [String], processes: [String], pids: [Int], kind: CloudListeningPortKind) {
        self.port = port
        self.addresses = addresses
        self.processes = processes
        self.pids = pids
        self.kind = kind
    }

    public var isSystem: Bool { kind.isSystem }

    /// Every binding is loopback, so only the authenticated cmux route reaches it.
    public var isLoopbackOnly: Bool {
        !addresses.isEmpty && addresses.allSatisfy {
            CmuxTuiSnapshotParser.ListeningPortBinding(port: port, address: $0).isLoopbackOnly
        }
    }
}

/// The one classification of a machine's listeners into the person's ports and
/// system ports. Port numbers decide only for listeners that are never web
/// previews; everything else is decided by the owning process, and a listener
/// whose owner is unknown is shown rather than hidden.
extension CloudListeningPortKind {
    /// Ports that are system-owned whatever process the inventory reports.
    /// 22 (SSH), 1337 (cmux-tui daemon), 8080 (image-internal listener), 53 (DNS).
    public static let systemPorts: [Int: CloudListeningPortKind] = {
        var ports: [Int: CloudListeningPortKind] = [53: .dns]
        for port in CmuxTuiSnapshotParser.internalPorts {
            ports[port] = switch port {
            case 22: .ssh
            case 1337: .cmux
            default: .image
            }
        }
        return ports
    }()

    /// Exact process names that are never the person's own service. cmux's own
    /// processes are named one by one (`ss` reports at most 15 characters of a
    /// name, hence `cmux-cloud-adap`), so a person's `cmux-demo` stays theirs.
    public static let systemProcesses: [String: CloudListeningPortKind] = [
        "cmux-tui": .cmux,
        "cmuxd": .cmux,
        "cmuxd-remote": .cmux,
        "cmux-cloud-adapter": .cmux,
        "cmux-cloud-adap": .cmux,
        "sshd": .ssh,
        "systemd-resolve": .dns,
        "systemd-resolved": .dns,
        "dnsmasq": .dns,
        "containerd": .container,
        "dockerd": .container,
        "Xvnc": .desktop,
        "Xtigervnc": .desktop,
        "x11vnc": .desktop,
        "websockify": .desktop,
        "novnc_proxy": .desktop,
    ]

    /// Classifies one port from its owners and bind addresses.
    ///
    /// - Parameter displayPortsOwned: `true` when the machine's Desktop owns the
    ///   VNC/noVNC slots, `false` when it has none, `nil` when the caller cannot
    ///   tell (the CLI): then those slots are system unless an app owns them.
    public static func classify(
        port: Int,
        addresses: [String],
        processes: [String],
        displayPortsOwned: Bool? = nil
    ) -> CloudListeningPortKind {
        if let kind = systemPorts[port] { return kind }
        let ownerKinds = processes.map(CloudListeningPortKind.init(processName:))
        if !ownerKinds.isEmpty, ownerKinds.allSatisfy(\.isSystem), let first = ownerKinds.first {
            return first
        }
        if !addresses.isEmpty, addresses.allSatisfy(isLoopbackAlias) { return .dns }
        if CmuxTuiSnapshotParser.displayPorts.contains(port) {
            let appOwned = ownerKinds.contains(.app)
            switch displayPortsOwned {
            case true?: return .desktop
            case false?: return .app
            case nil: return appOwned ? .app : .desktop
            }
        }
        return .app
    }

    /// The kind a single process name implies.
    public init(processName name: String) {
        self = Self.systemProcesses[name] ?? .app
    }

    /// systemd-resolved's stub listeners. Another 127/8 address is one someone
    /// bound on purpose, so it is classified like any other.
    static let resolverStubAddresses: Set<String> = ["127.0.0.53", "127.0.0.54"]

    /// True for the resolver stub's loopback addresses (127.0.0.53/54).
    static func isLoopbackAlias(_ raw: String) -> Bool {
        let bracketless = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let address = bracketless.split(separator: "%", maxSplits: 1).first.map(String.init) ?? bracketless
        let v4 = address.hasPrefix("::ffff:") ? String(address.dropFirst("::ffff:".count)) : address
        return resolverStubAddresses.contains(v4)
    }
}

/// Reading a machine's socket listing into classified ports.
extension CloudListeningPort {
    /// Parses an `ss -ltnp` / `netstat -ltnp` listing into classified ports.
    /// Returns `nil` when the listing holds diagnostics but no socket rows: the
    /// inventory itself failed, which is different from nothing listening.
    public static func inventory(socketListing: String, displayPortsOwned: Bool? = nil) -> [CloudListeningPort]? {
        guard let rows = listenerRows(socketListing) else { return nil }
        var addresses: [Int: Set<String>] = [:]
        var processes: [Int: Set<String>] = [:]
        var pids: [Int: Set<Int>] = [:]
        for row in rows {
            for binding in CmuxTuiSnapshotParser.listeningPortBindings(fromSocketListing: row) {
                addresses[binding.port, default: []].insert(binding.address)
                let owners = owners(ofListenerRow: row)
                processes[binding.port, default: []].formUnion(owners.map(\.name))
                pids[binding.port, default: []].formUnion(owners.compactMap(\.pid))
            }
        }
        return addresses.keys.sorted().map { port in
            let portAddresses = (addresses[port] ?? []).sorted()
            let portProcesses = (processes[port] ?? []).sorted()
            return CloudListeningPort(
                port: port,
                addresses: portAddresses,
                processes: portProcesses,
                pids: (pids[port] ?? []).sorted(),
                kind: CloudListeningPortKind.classify(port: port, addresses: portAddresses, processes: portProcesses, displayPortsOwned: displayPortsOwned)
            )
        }
    }

    /// The LISTEN rows of a listing, or `nil` when it is diagnostics only.
    static func listenerRows(_ socketListing: String) -> [String]? {
        var rows: [String] = []
        var socketRows = 0
        var diagnosticRows = 0
        for line in socketListing.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("State ") || text.hasPrefix("Proto ") || text.hasPrefix("Active Internet") { continue }
            // `ss` may include non-listening rows (an UNCONN socket or a
            // diagnostic line) beside the listeners; those rows do not void
            // a successful inventory.
            let fields = text.split(whereSeparator: { $0.isWhitespace })
            guard fields.contains("LISTEN") else {
                if isSocketRow(fields) { socketRows += 1 } else { diagnosticRows += 1 }
                continue
            }
            guard !CmuxTuiSnapshotParser.listeningPortBindings(fromSocketListing: text).isEmpty else {
                diagnosticRows += 1
                continue
            }
            socketRows += 1
            rows.append(text)
        }
        if socketRows == 0 && diagnosticRows > 0 { return nil }
        return rows
    }

    /// `ss` owners (`users:(("node",pid=2000,fd=12))`) or a netstat `2000/python3` column.
    static func owners(ofListenerRow line: String) -> [(name: String, pid: Int?)] {
        if let start = line.range(of: "users:((") {
            return line[start.lowerBound...].components(separatedBy: "(\"").dropFirst().compactMap { chunk in
                guard let end = chunk.firstIndex(of: "\"") else { return nil }
                let name = String(chunk[..<end])
                let pid = chunk.range(of: "pid=").flatMap { range -> Int? in
                    Int(chunk[range.upperBound...].prefix { $0.isNumber })
                }
                return name.isEmpty ? nil : (name, pid)
            }
        }
        if let field = line.split(whereSeparator: { $0.isWhitespace }).last,
           let slash = field.firstIndex(of: "/"), let pid = Int(field[..<slash]) {
            let name = String(field[field.index(after: slash)...])
            return name.isEmpty ? [] : [(name, pid)]
        }
        return []
    }

    private static func isSocketRow(_ fields: [Substring]) -> Bool {
        guard let first = fields.first?.uppercased() else { return false }
        return socketStates.contains(first) || first.hasPrefix("TCP") || first.hasPrefix("UDP")
    }

    private static let socketStates: Set<String> = [
        "UNCONN", "ESTAB", "SYN-SENT", "SYN-RECV", "FIN-WAIT-1", "FIN-WAIT-2",
        "TIME-WAIT", "CLOSE-WAIT", "LAST-ACK", "CLOSING", "CLOSED",
    ]
}

/// Who can reach a port beyond the owner's private preview, as the CLI's SHARED
/// column and the Share dialog name it. `unshared` (wire value `none`) means only the private address
/// (reachable through the owner's cmux VPN) exists.
public enum CloudPortSharing: String, Equatable, Sendable, CaseIterable {
    case unshared = "none"
    case personal
    case team
    case `public`

    /// Maps a publication `accessMode` (`personal`, `team`, `public`); unknown values read as `none`.
    public init(accessMode: String?) {
        self = accessMode.flatMap(CloudPortSharing.init(rawValue:)) ?? .unshared
    }

    /// When a port has several publications, the widest audience wins.
    public static func widest(_ values: [CloudPortSharing]) -> CloudPortSharing {
        values.max { $0.breadth < $1.breadth } ?? .unshared
    }

    var breadth: Int {
        switch self {
        case .unshared: 0
        case .personal: 1
        case .team: 2
        case .public: 3
        }
    }

    public var isPublic: Bool { self == .public }
}
