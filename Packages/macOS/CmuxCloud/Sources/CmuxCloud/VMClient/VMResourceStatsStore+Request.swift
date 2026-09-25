import Foundation

/// A request carries the resource mutation revision and its poll order.
extension VMResourceStatsStore {
    public struct Request: Sendable {
        public let machineID: String
        public let revision: UUID
        public let sequence: UInt64
    }

}
