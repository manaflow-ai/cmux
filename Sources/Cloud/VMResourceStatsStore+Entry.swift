import Foundation

/// Retained resource state for one machine; owned only by the shared store.
extension VMResourceStatsStore {
    struct Entry {
        var revision = UUID()
        var resizing = false
        var readSequence: UInt64 = 0
        var acceptedSequence: UInt64 = 0
        var stats: VMStats?
        var readTask: Task<VMStats, Error>?
    }
}
