/// Which reconnect a machine header's Reconnect runs (remote-groups-DESIGN.md 8.2).
public nonisolated enum MachineReconnectRoute: Equatable, Sendable {
    /// An SSH host: its own `remote.reconnect`, already a row of its header menu.
    case ssh
    /// A paired server: wake its link now instead of at the next backoff.
    case wakeServer
    /// A Cloud machine: retry its link now.
    case retryCloud
    /// This Mac or an unknown machine: nothing to reconnect.
    case none

    /// The route of a machine that is this Mac (`isLocal`), an SSH host, a paired server or a Cloud machine.
    /// - Parameters:
    ///   - isLocal: the machine is this Mac.
    ///   - isSSH: it is one of the app's SSH machines.
    ///   - isServer: it is a paired server.
    ///   - isCloud: it is a Cloud machine.
    public init(isLocal: Bool, isSSH: Bool, isServer: Bool, isCloud: Bool) {
        self = isLocal ? .none : isSSH ? .ssh : isServer ? .wakeServer : isCloud ? .retryCloud : .none
    }

    /// Whether the shared `machine.reconnect` row shows on the header: not where the header already
    /// has Reconnect (SSH) or has nothing to reconnect.
    public var showsSharedRow: Bool { self == .wakeServer || self == .retryCloud }
}
