import Foundation

/// One atomic rendering snapshot, including identities retained after operations retire.
public struct CloudMachineCreateProjection: Equatable, Sendable {
    /// Pending and recoverable creates in acceptance order.
    public internal(set) var operations: [CloudMachineCreateOperation] = []
    /// Provider machine IDs mapped to their original pending row identities.
    ///
    /// Aliases live for the account session. A missing machine in a partial or stale
    /// panel refresh cannot invalidate another panel's selection or expansion state.
    public internal(set) var adoptedOperationIDs: [String: UUID] = [:]
}
