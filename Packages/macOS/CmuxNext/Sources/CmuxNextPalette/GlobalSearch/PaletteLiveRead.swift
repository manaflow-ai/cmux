/// A page's text, read once as the page opens and searched while it is read
/// (Search All Windows): `value` starts as what is known at once (every tab's
/// title) and takes each update as it lands. A search reads `states()`, so it
/// answers from what is read so far and again on each change, never only
/// after the slowest read. Kept until the page is left or a row is chosen.
@MainActor
package final class PaletteLiveRead<Value: Sendable> {
    /// What has been read, and whether the read has ended.
    package struct State: Sendable {
        package let value: Value
        package let complete: Bool
    }

    package private(set) var state: State
    private let empty: Value
    private var task: Task<Void, Never>?
    private var watchers: [Int: AsyncStream<State>.Continuation] = [:]
    private var nextWatcher = 0

    // A generic main-actor class: an isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// Reads `updates` into `initial` with `apply`; `empty` is the value once released.
    package init<Update: Sendable>(_ initial: Value, empty: Value, updates: AsyncStream<Update>,
                                   apply: @escaping @Sendable (inout Value, Update) -> Void) {
        state = State(value: initial, complete: false)
        self.empty = empty
        // task-owner: the page's read; release() cancels it, which ends `updates`.
        task = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                var value = state.value
                // Drop the stored copy first, so `apply` mutates the only one (no copy per read).
                state = State(value: empty, complete: false)
                apply(&value, update)
                publish(State(value: value, complete: false))
            }
            guard let self, !Task.isCancelled else { return }
            publish(State(value: state.value, complete: true))
        }
    }

    /// The current state, then each change (coalesced to the newest); ends after the complete one.
    package func states() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        guard !state.complete else {
            continuation.finish()
            return stream
        }
        let id = nextWatcher
        nextWatcher += 1
        watchers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            // task-owner: one hop back to the main actor to forget this watcher.
            Task { @MainActor in self?.watchers[id] = nil }
        }
        return stream
    }

    private func publish(_ state: State) {
        self.state = state
        for continuation in watchers.values {
            continuation.yield(state)
            if state.complete { continuation.finish() }
        }
        if state.complete { watchers = [:] }
    }

    /// Stops a read still running and drops the text.
    package func release() {
        task?.cancel()
        task = nil
        state = State(value: empty, complete: true)
        // The searches end on the rows they showed: a chosen row's page shows no emptied search.
        for continuation in watchers.values { continuation.finish() }
        watchers = [:]
    }
}
