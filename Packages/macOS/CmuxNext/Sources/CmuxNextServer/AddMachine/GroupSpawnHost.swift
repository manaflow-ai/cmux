/// Where a workspace made with "New Workspace" in a group runs (remote-groups-DESIGN.md R6).
///
/// A group inside a remote host's section holds that host's workspaces, so its new workspace is
/// made on the same host: placement decides where work runs. An empty group, a group of this
/// Mac's workspaces, or an old group whose members run on several machines makes it on this Mac.
public nonisolated struct GroupSpawnHost<Machine: AnyObject> {
    /// The machine each current member of the group runs on.
    public let memberHomes: [Machine]
    /// This Mac's machine.
    public let local: Machine

    /// - Parameters:
    ///   - memberHomes: the machine each current member runs on.
    ///   - local: this Mac's machine.
    public init(memberHomes: [Machine], local: Machine) {
        self.memberHomes = memberHomes
        self.local = local
    }

    /// The machine every member runs on, else `local`.
    public var host: Machine {
        guard let first = memberHomes.first, memberHomes.allSatisfy({ $0 === first }) else { return local }
        return first
    }
}
