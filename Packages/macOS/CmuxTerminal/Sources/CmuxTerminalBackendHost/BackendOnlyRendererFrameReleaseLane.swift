internal import CmuxTerminalBackend
internal import Foundation

enum BackendOnlyRendererFrameReleasePriority: Sendable {
    case normal
    case recovery
}

enum BackendOnlyRendererFrameReleaseEnqueueResult: Equatable, Sendable {
    case accepted
    case capacityExceeded
    case stopped
}

enum BackendOnlyRendererFrameReleaseLaneFailure: Equatable, Sendable {
    case capacityExceeded
    case sendFailed
}

struct BackendOnlyRendererFrameReleaseLaneMetrics: Equatable, Sendable {
    var workerStarts: UInt64 = 0
    var sent: UInt64 = 0
    var outstanding: Int = 0
    var maximumOutstanding: Int = 0
    var sendFailures: UInt64 = 0
    var rejectedAfterStop: UInt64 = 0
}

/// Bounded, single-writer lane for renderer frame-release messages.
///
/// GPU completion callbacks enqueue without creating a task. One lifetime worker
/// serializes every accepted release, while a separate recovery quota guarantees
/// that receiver teardown can return frames even when ordinary completions fill
/// their quota.
final class BackendOnlyRendererFrameReleaseLane: @unchecked Sendable {
    typealias Send = @Sendable (BackendRendererFrameRelease) async -> Bool
    typealias FailureHandler = @Sendable (
        BackendOnlyRendererFrameReleaseLaneFailure
    ) -> Void

    private let core: Core
    private let workerTask: Task<Void, Never>

    init(
        normalCapacity: Int,
        recoveryCapacity: Int,
        send: @escaping Send,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        precondition(normalCapacity > 0)
        precondition(recoveryCapacity > 0)
        let signal = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let core = Core(
            normalCapacity: normalCapacity,
            recoveryCapacity: recoveryCapacity,
            signal: signal.continuation,
            send: send,
            onFailure: onFailure
        )
        self.core = core
        workerTask = Task.detached(priority: .utility) {
            await core.run(signals: signal.stream)
        }
    }

    deinit {
        core.requestStop()
    }

    func enqueue(
        _ release: BackendRendererFrameRelease,
        priority: BackendOnlyRendererFrameReleasePriority
    ) -> BackendOnlyRendererFrameReleaseEnqueueResult {
        core.enqueue(release, priority: priority)
    }

    func metrics() -> BackendOnlyRendererFrameReleaseLaneMetrics {
        core.metrics()
    }

    func waitUntilIdle() async {
        await core.waitUntilIdle()
    }

    func stop() async {
        core.requestStop()
        await workerTask.value
    }
}

private extension BackendOnlyRendererFrameReleaseLane {
    final class Core: @unchecked Sendable {
        private struct Entry: Sendable {
            let release: BackendRendererFrameRelease
            let priority: BackendOnlyRendererFrameReleasePriority
        }

        private struct State {
            var queue: RingBuffer<Entry>
            var accepting = true
            var normalOutstanding = 0
            var recoveryOutstanding = 0
            var idleWaiters: [CheckedContinuation<Void, Never>] = []
            var metrics = BackendOnlyRendererFrameReleaseLaneMetrics(
                workerStarts: 1
            )
        }

        private let lock = NSLock()
        private let normalCapacity: Int
        private let recoveryCapacity: Int
        private let signal: AsyncStream<Void>.Continuation
        private let send: Send
        private let onFailure: FailureHandler
        private var state: State

        init(
            normalCapacity: Int,
            recoveryCapacity: Int,
            signal: AsyncStream<Void>.Continuation,
            send: @escaping Send,
            onFailure: @escaping FailureHandler
        ) {
            self.normalCapacity = normalCapacity
            self.recoveryCapacity = recoveryCapacity
            self.signal = signal
            self.send = send
            self.onFailure = onFailure
            state = State(
                queue: RingBuffer(
                    capacity: normalCapacity + recoveryCapacity
                )
            )
        }

        func enqueue(
            _ release: BackendRendererFrameRelease,
            priority: BackendOnlyRendererFrameReleasePriority
        ) -> BackendOnlyRendererFrameReleaseEnqueueResult {
            let result: BackendOnlyRendererFrameReleaseEnqueueResult
            var shouldSignal = false
            var failure: BackendOnlyRendererFrameReleaseLaneFailure?

            lock.lock()
            if !state.accepting {
                state.metrics.rejectedAfterStop += 1
                result = .stopped
            } else if !hasCapacity(for: priority) {
                result = .capacityExceeded
                failure = .capacityExceeded
            } else if !state.queue.append(
                Entry(release: release, priority: priority)
            ) {
                // The per-priority outstanding quotas make this unreachable,
                // including while one item is in flight. Keep the guard so a
                // future quota change fails closed instead of losing a release.
                result = .capacityExceeded
                failure = .capacityExceeded
            } else {
                incrementOutstanding(for: priority)
                state.metrics.outstanding += 1
                state.metrics.maximumOutstanding = max(
                    state.metrics.maximumOutstanding,
                    state.metrics.outstanding
                )
                result = .accepted
                shouldSignal = true
            }
            lock.unlock()

            if let failure { onFailure(failure) }
            if shouldSignal { signal.yield() }
            return result
        }

        func metrics() -> BackendOnlyRendererFrameReleaseLaneMetrics {
            lock.lock()
            defer { lock.unlock() }
            return state.metrics
        }

        func waitUntilIdle() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if state.metrics.outstanding == 0 {
                    lock.unlock()
                    continuation.resume()
                } else {
                    state.idleWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func requestStop() {
            lock.lock()
            let shouldFinish = state.accepting
            state.accepting = false
            lock.unlock()
            if shouldFinish { signal.finish() }
        }

        func run(signals: AsyncStream<Void>) async {
            for await _ in signals {
                await drainAvailable()
            }
            await drainAvailable()
        }

        private func drainAvailable() async {
            while let entry = popFirst() {
                let didSend = await send(entry.release)
                complete(entry, didSend: didSend)
            }
        }

        private func popFirst() -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return state.queue.popFirst()
        }

        private func complete(_ entry: Entry, didSend: Bool) {
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            decrementOutstanding(for: entry.priority)
            state.metrics.outstanding -= 1
            if didSend {
                state.metrics.sent += 1
            } else {
                state.metrics.sendFailures += 1
            }
            if state.metrics.outstanding == 0 {
                waiters = state.idleWaiters
                state.idleWaiters.removeAll(keepingCapacity: true)
            }
            lock.unlock()

            if !didSend { onFailure(.sendFailed) }
            for waiter in waiters { waiter.resume() }
        }

        private func hasCapacity(
            for priority: BackendOnlyRendererFrameReleasePriority
        ) -> Bool {
            switch priority {
            case .normal:
                state.normalOutstanding < normalCapacity
            case .recovery:
                state.recoveryOutstanding < recoveryCapacity
            }
        }

        private func incrementOutstanding(
            for priority: BackendOnlyRendererFrameReleasePriority
        ) {
            switch priority {
            case .normal:
                state.normalOutstanding += 1
            case .recovery:
                state.recoveryOutstanding += 1
            }
        }

        private func decrementOutstanding(
            for priority: BackendOnlyRendererFrameReleasePriority
        ) {
            switch priority {
            case .normal:
                state.normalOutstanding -= 1
            case .recovery:
                state.recoveryOutstanding -= 1
            }
        }
    }
}

private struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) -> Bool {
        guard count < storage.count else { return false }
        storage[tail] = element
        tail = (tail + 1) % storage.count
        count += 1
        return true
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }
}
