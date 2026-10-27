/// The main-actor consumer the registry calls: it posts each call through the link and returns.
@MainActor
final class AsyncMemoryConsumerForwarder: MemoryConsumer {
    private let link: AsyncMemoryConsumerLink

    init(link: AsyncMemoryConsumerLink) {
        self.link = link
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {
        link.post(.update, limit: limit)
    }

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        link.post(.release, limit: slice.limit)
        return .done
    }

    var memoryUsage: MemoryUsage? {
        link.lastUsage
    }
}

/// The state the main actor and the delivery share: the weak consumer, the newest limit, which calls
/// are pending and whether a delivery is running. One delivery runs at a time, so calls stay in order.
final class AsyncMemoryConsumerLink: Sendable {
    enum Call: Sendable {
        case update
        case release
    }

    private enum Step: Sendable {
        case update(any AsyncMemoryConsumer, MemoryLimit)
        case release(any AsyncMemoryConsumer, MemoryLimit)
    }

    private struct State {
        weak var consumer: (any AsyncMemoryConsumer)?
        var limit = MemoryLimit.default
        var pendingUpdate = false
        var pendingRelease = false
        var delivering = false
        var lastUsage: MemoryUsage?

        init(consumer: any AsyncMemoryConsumer) {
            self.consumer = consumer
        }

        /// Marks `call` pending at `newLimit`; true when no delivery is running and one must start.
        mutating func post(_ call: Call, limit newLimit: MemoryLimit) -> Bool {
            guard consumer != nil else { return false }
            limit = newLimit
            switch call {
            case .update: pendingUpdate = true
            case .release: pendingRelease = true
            }
            guard !delivering else { return false }
            delivering = true
            return true
        }

        /// The next call to make, or nil (and the delivery ends) when none is pending or the consumer
        /// is gone.
        mutating func next() -> Step? {
            guard let consumer = self.consumer, pendingUpdate || pendingRelease else {
                pendingUpdate = false
                pendingRelease = false
                delivering = false
                if self.consumer == nil { lastUsage = nil }
                return nil
            }
            if pendingUpdate {
                pendingUpdate = false
                return .update(consumer, limit)
            }
            pendingRelease = false
            return .release(consumer, limit)
        }

        /// Keeps what a call returned, unless the consumer was cancelled or went during the call.
        mutating func record(_ usage: MemoryUsage?) {
            lastUsage = consumer == nil ? nil : usage
        }

        /// What the consumer last returned, or nil when it is gone.
        var currentUsage: MemoryUsage? {
            consumer == nil ? nil : lastUsage
        }
    }

    private let state: Mutex<State>
    private let hop: AsyncMemoryConsumerHop

    init(consumer: any AsyncMemoryConsumer, hop: AsyncMemoryConsumerHop) {
        state = Mutex(State(consumer: consumer))
        self.hop = hop
    }

    /// Marks `call` pending at `limit`, and posts one delivery when none is pending or running.
    func post(_ call: Call, limit: MemoryLimit) {
        let start = state.withLock { $0.post(call, limit: limit) }
        if start { hop { await self.deliver() } }
    }

    /// What the consumer returned from its last call, or nil before its first and once it is gone
    /// (cancelled or deallocated), so a dead consumer never reports its old footprint.
    var lastUsage: MemoryUsage? {
        state.withLock { $0.currentUsage }
    }

    /// Whether the consumer still exists and the link was not cancelled.
    var isConsumerAlive: Bool {
        state.withLock { $0.consumer != nil }
    }

    /// Forgets the consumer and its last usage. Every pending call is dropped; a call a running
    /// delivery already took may still reach the consumer once (it holds the consumer strongly for
    /// that call), and its result is not kept.
    func cancel() {
        state.withLock { state in
            state.consumer = nil
            state.lastUsage = nil
        }
    }

    private func deliver() async {
        while let step = state.withLock({ $0.next() }) {
            let usage: MemoryUsage?
            switch step {
            case .update(let consumer, let limit): usage = await consumer.updateMemoryLimit(limit)
            case .release(let consumer, let limit): usage = await consumer.releaseMemory(downTo: limit)
            }
            state.withLock { $0.record(usage) }
        }
    }
}
