/// The "Move Chief to…" list. Stub.
struct ChiefMoveTargets {
    enum Kind: Equatable {
        case local(home: String)
        case ssh(destination: String)
        case server
        case cloud(staging: Bool)
    }

    struct Host {
        var machineID: String
        var name: String
        var kind: Kind
        var isOnline: Bool
        var isRemoteGroup: Bool
    }

    enum Cloud: Equatable { case signedIn(staging: Bool), signedOut }

    static let cloudID = "cloud"

    let targets: [ChiefMoveTarget]

    init(localHome: String, hosts: [Host], cloud: Cloud) { targets = [] }
}
