import Foundation

struct SimulatorLocationRoutePendingTransaction: Codable, Equatable, Sendable {
    let ownershipToken: UUID
    let ownerProcessIdentity: SimulatorProcessIdentity
    let replacement: SimulatorLocationRouteRecoverySnapshot?

    var isOwnedByRunningProcess: Bool {
        ownerProcessIdentity.isRunning
    }
}
