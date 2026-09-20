import Foundation

/// A request carries the resource mutation revision and its poll order.
extension VMResourceStatsStore {
    struct Request: Sendable {
        let machineID: String
        let revision: UUID
        let sequence: UInt64
    }

}
