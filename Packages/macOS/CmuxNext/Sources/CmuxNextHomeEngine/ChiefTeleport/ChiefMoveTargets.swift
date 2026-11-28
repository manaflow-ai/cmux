public import Foundation

/// The "Move Chief To…" list (remote-groups-DESIGN.md slice 6, chief-migration-DESIGN.md 8a): This Mac
/// first, then every SSH or paired-server host the person made a remote group (a server moves over SSH like
/// an SSH host), then cmux Cloud. Pure:
/// the handler reads the machines, this decides the list.
public nonisolated struct ChiefMoveTargets: Sendable {
    /// Where a target is, which decides its `--to` value.
    public enum Kind: Equatable, Sendable {
        /// A Chief home on this Mac (`local:<dir>`).
        case local(home: String)
        /// An SSH host (`ssh:<destination>`): what `ssh` takes on this Mac.
        case ssh(destination: String)
        /// A paired server, moved over SSH like an SSH host (`ssh:<destination>`): its SSH route's
        /// destination, or the server name as a host name for an overlay route; nil when no SSH
        /// route exists.
        case server(destination: String?)
        /// The account's Cloud Chief (`cloud`; `staging`: the app signs in to another Cloud than
        /// production, and the move goes to that one, `cloud:<its API>`).
        case cloud(staging: Bool)
    }

    /// A machine the list may show.
    public struct Host: Sendable {
        public var machineID: String
        public var name: String
        public var kind: Kind
        public var isOnline: Bool
        /// The person made it a remote group (its section's `host_group`).
        public var isRemoteGroup: Bool

        public init(machineID: String, name: String, kind: Kind, isOnline: Bool, isRemoteGroup: Bool) {
            self.machineID = machineID
            self.name = name
            self.kind = kind
            self.isOnline = isOnline
            self.isRemoteGroup = isRemoteGroup
        }
    }

    /// The person's Cloud session.
    public enum Cloud: Equatable, Sendable {
        /// Signed in: `api` is the Cloud API the app uses when it is not production (staging, a
        /// development backend), nil for production. A move goes to the same Cloud the app reads, where
        /// its session is valid and where the app finds the moved Chief.
        case signedIn(api: URL?)
        case signedOut
    }

    /// The machine id of the cmux Cloud entry.
    public static let cloudID = "cloud"
    /// The machine id of the This Mac entry.
    public static let localID = "local"

    public let targets: [ChiefMoveTarget]

    /// - Parameters:
    ///   - localHome: the Chief home a move back to this Mac lands in.
    ///   - hosts: the connected or remembered machines; only remote groups list, Cloud VMs never
    ///     (`--to cloud` is the account's Cloud Chief, not a VM).
    ///   - cloud: whether the app is signed in to Cloud, and to which one.
    public init(localHome: String, hosts: [Host], cloud: Cloud) {
        let wireCloud: WireCloud = switch cloud {
        case .signedIn(let api): WireCloud(type: "signedIn", api: api?.absoluteString)
        case .signedOut: WireCloud(type: "signedOut", api: nil)
        }
        let request = TargetsRequest(
            localHome: localHome,
            hosts: hosts.map { WireHost(machineID: $0.machineID, name: $0.name, kind: WireKind($0.kind), isOnline: $0.isOnline,
                                        isRemoteGroup: $0.isRemoteGroup) },
            cloud: wireCloud)
        let wire: [WireTarget] = dockRule("dock.move_targets", request, fallback: [])
        targets = wire.map {
            ChiefMoveTarget(machineID: $0.machineID, name: $0.name, kind: $0.kind.kind, to: $0.to,
                            disabledReason: $0.disabledReason.flatMap(ChiefMoveTarget.DisabledReason.init(wire:)))
        }
    }

    nonisolated private struct TargetsRequest: Encodable {
        var localHome: String
        var hosts: [WireHost]
        var cloud: WireCloud
    }

    nonisolated private struct WireHost: Encodable {
        var machineID: String
        var name: String
        var kind: WireKind
        var isOnline: Bool
        var isRemoteGroup: Bool
    }

    nonisolated private struct WireCloud: Encodable {
        var type: String
        var api: String?
    }

    nonisolated private struct WireTarget: Decodable {
        var machineID: String
        var name: String
        var kind: WireKind
        var to: String?
        var disabledReason: String?
    }
}

/// ``ChiefMoveTargets/Kind`` as the dock ops write it (`{"type": "ssh", "destination": …}`).
nonisolated struct WireKind: Codable, Sendable {
    var type: String
    var home: String?
    var destination: String?
    var staging: Bool?

    init(_ kind: ChiefMoveTargets.Kind) {
        switch kind {
        case .local(let home): type = "local"; self.home = home
        case .ssh(let destination): type = "ssh"; self.destination = destination
        case .server(let destination): type = "server"; self.destination = destination
        case .cloud(let staging): type = "cloud"; self.staging = staging
        }
    }

    var kind: ChiefMoveTargets.Kind {
        switch type {
        case "local": .local(home: home ?? "")
        case "ssh": .ssh(destination: destination ?? "")
        case "server": .server(destination: destination)
        default: .cloud(staging: staging ?? false)
        }
    }
}

private extension ChiefMoveTarget.DisabledReason {
    nonisolated init?(wire: String) {
        switch wire {
        case "offline": self = .offline
        case "noSSHRoute": self = .noSSHRoute
        case "signInNeeded": self = .signInNeeded
        default: return nil
        }
    }
}
