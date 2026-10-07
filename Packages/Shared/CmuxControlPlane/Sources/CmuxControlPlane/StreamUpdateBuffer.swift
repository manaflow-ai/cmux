import os

/// One subscriber's queue of stream updates, bounded (E1). When the
/// subscriber falls `limit` updates behind, the client drops the backlog and
/// repairs the mirror with a fresh snapshot, so memory stays bounded and the
/// mirror stays correct. One consumer.
final class StreamUpdateBuffer: Sendable {
    private struct State {
        var items: [StreamUpdate] = []
        var head = 0
        var finished = false
        var waiter: CheckedContinuation<StreamUpdate?, Never>?
    }

    let limit: Int
    // carve-out: the client actor pushes, the subscriber's task pops; one
    // short critical section each, never held across a suspension.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var stream: AsyncStream<StreamUpdate> {
        AsyncStream(unfolding: { [self] in await next() })
    }

    /// Queues `update`; false (nothing queued) when the backlog is full.
    func push(_ update: StreamUpdate) -> Bool {
        let (accepted, waiter) = state.withLock { state -> (Bool, CheckedContinuation<StreamUpdate?, Never>?) in
            guard !state.finished else { return (true, nil) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (true, waiter)
            }
            guard state.items.count - state.head < limit else { return (false, nil) }
            state.items.append(update)
            return (true, nil)
        }
        waiter?.resume(returning: update)
        return accepted
    }

    /// Drops every queued update (a snapshot follows).
    func clear() {
        state.withLock { state in
            state.items.removeAll()
            state.head = 0
        }
    }

    /// The subscriber reads what is queued, then the sequence ends.
    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<StreamUpdate?, Never>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    func next() async -> StreamUpdate? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StreamUpdate?, Never>) in
                let taken = state.withLock { state -> StreamUpdate?? in
                    if state.head < state.items.count {
                        let item = state.items[state.head]
                        state.head += 1
                        if state.head == state.items.count {
                            state.items.removeAll(keepingCapacity: true)
                            state.head = 0
                        } else if state.head > 256, state.head * 2 > state.items.count {
                            state.items.removeFirst(state.head)
                            state.head = 0
                        }
                        return .some(item)
                    }
                    if state.finished || Task.isCancelled { return .some(nil) }
                    state.waiter = continuation
                    return nil
                }
                if let taken { continuation.resume(returning: taken) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<StreamUpdate?, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }
}
