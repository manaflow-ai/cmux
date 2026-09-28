/// One atomic snapshot of the machines every list must omit.
public struct CloudMachineDeletionProjection: Equatable, Sendable {
    /// Machines with a destroy in flight, and confirmed deletions that a fleet
    /// read started after the confirmation has not yet omitted.
    public internal(set) var hiddenMachineIDs: Set<String> = []
}
