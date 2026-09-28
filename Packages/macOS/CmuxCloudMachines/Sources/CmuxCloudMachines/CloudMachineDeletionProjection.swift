/// One atomic snapshot of the machines every list must omit.
public struct CloudMachineDeletionProjection: Equatable, Sendable {
    /// Machines with a destroy in flight, and confirmed deletions of this account.
    public internal(set) var hiddenMachineIDs: Set<String> = []
}
