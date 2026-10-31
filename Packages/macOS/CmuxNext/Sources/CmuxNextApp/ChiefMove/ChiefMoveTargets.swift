/// The "Move Chief To…" list (remote-groups-DESIGN.md slice 6, chief-migration-DESIGN.md 8a): This Mac
/// first, then every SSH or paired-server host the person made a remote group (a server moves over SSH like
/// an SSH host), then cmux Cloud. Pure:
/// the handler reads the machines, this decides the list.
struct ChiefMoveTargets {
    /// Where a target is, which decides its `--to` value.
    enum Kind: Equatable {
        /// A Chief home on this Mac (`local:<dir>`).
        case local(home: String)
        /// An SSH host (`ssh:<destination>`): what `ssh` takes on this Mac.
        case ssh(destination: String)
        /// A paired server, moved over SSH like an SSH host (`ssh:<destination>`): its SSH route's
        /// destination, or the server name as a host name for an overlay route; nil when no SSH
        /// route exists.
        case server(destination: String?)
        /// The account's Cloud Chief (`cloud`, or `cloud:staging` when the app signs in to staging).
        case cloud(staging: Bool)
    }

    /// A machine the list may show.
    struct Host {
        var machineID: String
        var name: String
        var kind: Kind
        var isOnline: Bool
        /// The person made it a remote group (its section's `host_group`).
        var isRemoteGroup: Bool
    }

    /// The person's Cloud session.
    enum Cloud: Equatable { case signedIn(staging: Bool), signedOut }

    /// The machine id of the cmux Cloud entry.
    static let cloudID = "cloud"
    static let localID = "local"

    let targets: [ChiefMoveTarget]

    /// - Parameters:
    ///   - localHome: the Chief home a move back to this Mac lands in.
    ///   - hosts: the connected or remembered machines; only remote groups list, Cloud VMs never
    ///     (`--to cloud` is the account's Cloud Chief, not a VM).
    ///   - cloud: whether the app is signed in to Cloud, and to staging.
    init(localHome: String, hosts: [Host], cloud: Cloud) {
        var list = [ChiefMoveTarget(machineID: Self.localID, name: "", kind: .local(home: localHome), to: "local:\(localHome)", disabledReason: nil)]
        for host in hosts where host.isRemoteGroup {
            switch host.kind {
            case .ssh(let destination):
                list.append(ChiefMoveTarget(machineID: host.machineID, name: host.name, kind: host.kind, to: "ssh:\(destination)",
                                            disabledReason: host.isOnline ? nil : .offline))
            case .server(let destination?):
                list.append(ChiefMoveTarget(machineID: host.machineID, name: host.name, kind: host.kind, to: "ssh:\(destination)",
                                            disabledReason: host.isOnline ? nil : .offline))
            case .server(nil):
                list.append(ChiefMoveTarget(machineID: host.machineID, name: host.name, kind: host.kind, to: nil, disabledReason: .noSSHRoute))
            case .local, .cloud:
                continue
            }
        }
        switch cloud {
        case .signedIn(let staging):
            list.append(ChiefMoveTarget(machineID: Self.cloudID, name: "", kind: .cloud(staging: staging),
                                        to: staging ? "cloud:staging" : "cloud", disabledReason: nil))
        case .signedOut:
            list.append(ChiefMoveTarget(machineID: Self.cloudID, name: "", kind: .cloud(staging: false), to: "cloud", disabledReason: .signInNeeded))
        }
        targets = list
    }
}
