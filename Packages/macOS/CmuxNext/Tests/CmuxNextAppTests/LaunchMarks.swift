import os

/// The launch marks a launch read records, in order, from any thread (its `mark` runs on the read's lane).
nonisolated final class LaunchMarks: Sendable {
    private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// The marks so far.
    var names: [String] { recorded.withLock { $0 } }

    /// Records `name` (pass as a launch read's `mark`).
    func record(_ name: String) {
        recorded.withLock { $0.append(name) }
    }
}
