import Foundation

/// The latest byte count per transfer, written from the synchronous progress
/// callback and read when a run stops, so the journal shows where it paused.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: UInt64] = [:]

    func set(_ id: String, _ value: UInt64) {
        lock.withLock { values[id] = value }
    }

    func take(_ id: String) -> UInt64? {
        lock.withLock { values.removeValue(forKey: id) }
    }
}
