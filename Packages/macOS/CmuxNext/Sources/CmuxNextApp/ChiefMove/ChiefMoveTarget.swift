/// One "Move Chief To…" target (remote-groups-DESIGN.md slice 6, chief-migration-DESIGN.md 8a): a
/// place the Chief can move to, the `--to` value the move takes, or why it is greyed out.
struct ChiefMoveTarget: Equatable {
    /// Why a listed target cannot be picked now.
    enum DisabledReason: Equatable {
        /// The host is not connected.
        case offline
        /// A paired server with no SSH route (its name is not a usable host name).
        case noSSHRoute
        /// cmux Cloud needs the person's Cloud sign-in.
        case signInNeeded
    }

    /// The machine id (`MachineRegistry`), `local`, or ``ChiefMoveTargets/cloudID``.
    var machineID: String
    var name: String
    var kind: ChiefMoveTargets.Kind
    /// The move's `--to` value; nil when the kind is not a move target.
    var to: String?
    var disabledReason: DisabledReason?
}
