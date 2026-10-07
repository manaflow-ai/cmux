import Network

/// What NWPathMonitor reported last, reduced to what route decisions need.
public struct DirectPathSnapshot: Sendable, Hashable {
    /// The system has a usable path (`NWPath.Status.satisfied`).
    public var isSatisfied: Bool
    public var interfaces: [DirectInterface]

    public init(isSatisfied: Bool, interfaces: [DirectInterface]) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        interfaces = path.availableInterfaces.map { interface in
            let kind: DirectInterface.Kind = switch interface.type {
            case .wifi: .wifi
            case .wiredEthernet: .wired
            case .cellular: .cellular
            case .loopback: .loopback
            case .other: .other
            @unknown default: .other
            }
            return DirectInterface(name: interface.name, kind: kind)
        }
    }

    public var hasTunnel: Bool { interfaces.contains(where: \.isTunnel) }

    public var hasLocalNetwork: Bool { interfaces.contains(where: \.isLocalNetwork) }
}
