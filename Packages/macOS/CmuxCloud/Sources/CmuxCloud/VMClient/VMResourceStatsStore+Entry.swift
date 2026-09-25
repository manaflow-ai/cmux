import Foundation

/// Retained resource state for one machine; owned only by the shared store.
extension VMResourceStatsStore {
    public struct Entry: Sendable {
        public var revision = UUID()
        public var resizing = false
        var readSequence: UInt64 = 0
        var acceptedSequence: UInt64 = 0
        public var stats: VMStats?

        public init(
            revision: UUID = UUID(),
            resizing: Bool = false,
            readSequence: UInt64 = 0,
            acceptedSequence: UInt64 = 0,
            stats: VMStats? = nil
        ) {
            self.revision = revision
            self.resizing = resizing
            self.readSequence = readSequence
            self.acceptedSequence = acceptedSequence
            self.stats = stats
        }
    }
}
