public import CmuxNextCompat

/// Writes the registry id each handshake reports (``LaunchSnapshotLocation/recordRegistry(_:session:)``) one at a
/// time, latest wins: an id that arrives while a write is running replaces any id still waiting, and is written
/// after it. Two writes never race, so the file ends with the newest id: an older one left behind made the next
/// launch skip this home's own snapshot, or draw another session's (cmuxterm-hq#12660).
public final class LaunchRegistryRecorder: Sendable {
    private struct Pending: Sendable {
        var id: String
        var session: String
        var location: LaunchSnapshotLocation
    }

    private struct State {
        var pending: Pending?
        var writing = false
    }

    private let state = Mutex(State())
    /// Runs one drain off the calling thread (a file write blocks); tests run it by hand.
    private let start: @Sendable (@escaping @Sendable () -> Void) -> Void

    public init(start: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { drain in
        // task-owner: none; it writes the waiting ids, a few bytes each, and ends when none waits.
        Task.detached(priority: .utility) { drain() }
    }) {
        self.start = start
    }

    /// Records `id` for `session` in `location`'s folder after any write already running.
    public func record(_ id: String, session: String, location: LaunchSnapshotLocation) {
        let starts = state.withLock { state in
            state.pending = Pending(id: id, session: session, location: location)
            guard !state.writing else { return false }
            state.writing = true
            return true
        }
        if starts { start { [self] in drain() } }
    }

    /// Writes the waiting id until none waits.
    private func drain() {
        while let next = state.withLock({ state -> Pending? in
            guard let next = state.pending else { state.writing = false; return nil }
            state.pending = nil
            return next
        }) {
            next.location.recordRegistry(next.id, session: next.session)
        }
    }
}
