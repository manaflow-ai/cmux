/// One "Move Chief To…" target (remote-groups-DESIGN.md slice 6, chief-migration-DESIGN.md 8a): a
/// place the Chief can move to, the `--to` value the move takes, or why it is greyed out.
public nonisolated struct ChiefMoveTarget: Equatable, Sendable {
    /// Why a listed target cannot be picked now.
    public enum DisabledReason: Equatable, Sendable {
        /// The host is not connected.
        case offline
        /// A paired server with no SSH route (its name is not a usable host name).
        case noSSHRoute
        /// cmux Cloud needs the person's Cloud sign-in.
        case signInNeeded
    }

    /// The machine id (`MachineRegistry`), `local`, or ``ChiefMoveTargets/cloudID``.
    public var machineID: String
    /// The host's group name (empty for This Mac and cmux Cloud, which ``displayName`` names).
    public var name: String
    public var kind: ChiefMoveTargets.Kind
    /// The move's `--to` value; nil when the kind is not a move target.
    public var to: String?
    public var disabledReason: DisabledReason?

    public init(machineID: String, name: String, kind: ChiefMoveTargets.Kind, to: String?, disabledReason: DisabledReason?) {
        self.machineID = machineID
        self.name = name
        self.kind = kind
        self.to = to
        self.disabledReason = disabledReason
    }
}
