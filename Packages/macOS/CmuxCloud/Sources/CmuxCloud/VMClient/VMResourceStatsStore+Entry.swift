import Foundation

/// Retained resource state for one machine; owned only by the shared store.
extension VMResourceStatsStore {
    public struct Entry: Sendable {
        public var revision = UUID()
        public var resizing = false
        var readSequence: UInt64 = 0
        var acceptedSequence: UInt64 = 0
        public var stats: VMStats?
    }
}
