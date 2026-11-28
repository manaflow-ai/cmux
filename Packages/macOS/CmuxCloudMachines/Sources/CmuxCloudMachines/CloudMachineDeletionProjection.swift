/// One atomic snapshot of the machines every list must omit.
public struct CloudMachineDeletionProjection: Equatable, Sendable {
    /// Machines with a destroy in flight, and confirmed deletions of this account.
    public internal(set) var hiddenMachineIDs: Set<String> = []
    /// The hidden machines whose destroy request has not reported an outcome;
    /// only these can come back, so only these need state kept for a rollback.
    public internal(set) var pendingMachineIDs: Set<String> = []
}
