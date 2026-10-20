import Foundation
@testable import CmuxSimulator

struct LegacyLocationRouteRecoveryRecord: Codable {
    let deviceIdentifier: String
    let initialCoordinate: SimulatorLocationCoordinate
    let state: SimulatorLocationRouteRecoveryState
    let ownershipToken: UUID
    let ownerProcessIdentity: SimulatorProcessIdentity
}
