/// Which reconnect a machine header's Reconnect runs. Stub: not routed yet.
enum MachineReconnectRoute: Equatable {
    case ssh, wakeServer, retryCloud, none

    init(isLocal: Bool, isSSH: Bool, isServer: Bool, isCloud: Bool) { self = .none }

    var showsSharedRow: Bool { false }
}
