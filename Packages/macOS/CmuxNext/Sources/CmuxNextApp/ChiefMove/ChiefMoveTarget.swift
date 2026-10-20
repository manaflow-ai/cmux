/// One "Move Chief to…" target. Stub.
struct ChiefMoveTarget: Equatable {
    enum DisabledReason: Equatable { case offline, notSupportedYet, signInNeeded }
    var machineID: String
    var name: String
    var to: String?
    var disabledReason: DisabledReason?
}
