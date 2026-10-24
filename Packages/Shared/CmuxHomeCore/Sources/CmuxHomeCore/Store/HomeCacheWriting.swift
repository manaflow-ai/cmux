import Foundation

/// Where ``HomeClientViewCache`` hands its states: the ``HomeCache`` actor, or a test's writer
/// that controls when a write ends.
protocol HomeCacheWriting: Sendable {
    /// Writes `state` unless `writer` already wrote a newer one; true when everything it holds is
    /// on disk (or a newer state replaced it).
    func write(_ state: HomeCacheState, sequence: UInt64, writer: UUID) async -> Bool
}

extension HomeCache: HomeCacheWriting {}
