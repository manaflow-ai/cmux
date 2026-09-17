internal import CmuxTerminalBackend
internal import Foundation

/// Synchronous GPU admission cannot suspend. This private serial queue owns all
/// mutable state, and no callback reenters the queue while `sync` is active.
final class BackendOnlyRendererFrameReleaseCore: @unchecked Sendable {
    private typealias Entry = BackendOnlyRendererFrameReleaseEntry
    private typealias State = BackendOnlyRendererFrameReleaseState
    private typealias Send = BackendOnlyRendererFrameReleaseLane.Send
    private typealias FailureHandler = BackendOnlyRendererFrameReleaseLane.FailureHandler

    private let isolationQueue = DispatchQueue(
        label: "com.cmux.backend-only.renderer-frame-release"
    )
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
            queue: BackendOnlyRendererFrameReleaseRingBuffer(
                capacity: normalCapacity + recoveryCapacity
            )
        )
    }

    func enqueue(
        _ release: BackendRendererFrameRelease,
        priority: BackendOnlyRendererFrameReleasePriority
    ) -> BackendOnlyRendererFrameReleaseEnqueueResult {
        let decision = isolationQueue.sync {
            enqueueIsolated(release, priority: priority)
        }
        if let failure = decision.failure {
            onFailure(failure)
        }
        if decision.shouldSignal {
            signal.yield()
        }
        return decision.result
    }

    func metrics() -> BackendOnlyRendererFrameReleaseLaneMetrics {
        isolationQueue.sync { state.metrics }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let resumeNow = isolationQueue.sync {
                guard state.metrics.outstanding != 0 else { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func requestStop() {
        let shouldFinish = isolationQueue.sync {
            let wasAccepting = state.accepting
            state.accepting = false
            return wasAccepting
        }
        if shouldFinish {
            signal.finish()
        }
    }

    func run(signals: AsyncStream<Void>) async {
        for await _ in signals {
            await drainAvailable()
        }
        await drainAvailable()
    }

    private func drainAvailable() async {
        while let entry = isolationQueue.sync(execute: { state.queue.popFirst() }) {
            let didSend = await send(entry.release)
            complete(entry, didSend: didSend)
        }
    }

    private func enqueueIsolated(
        _ release: BackendRendererFrameRelease,
        priority: BackendOnlyRendererFrameReleasePriority
    ) -> BackendOnlyRendererFrameReleaseEnqueueDecision {
        if !state.accepting {
            state.metrics.rejectedAfterStop += 1
            return .init(result: .stopped)
        }
        guard hasCapacity(for: priority),
              state.queue.append(Entry(release: release, priority: priority))
        else {
            state.metrics.capacityFailures += 1
            return .init(result: .capacityExceeded, failure: .capacityExceeded)
        }
        incrementOutstanding(for: priority)
        state.metrics.outstanding += 1
        state.metrics.maximumOutstanding = max(
            state.metrics.maximumOutstanding,
            state.metrics.outstanding
        )
        return .init(result: .accepted, shouldSignal: true)
    }

    private func complete(_ entry: Entry, didSend: Bool) {
        let waiters = isolationQueue.sync {
            decrementOutstanding(for: entry.priority)
            state.metrics.outstanding -= 1
            if didSend {
                state.metrics.sent += 1
            } else {
                state.metrics.sendFailures += 1
            }
            guard state.metrics.outstanding == 0 else {
                return [CheckedContinuation<Void, Never>]()
            }
            let waiters = state.idleWaiters
            state.idleWaiters.removeAll(keepingCapacity: true)
            return waiters
        }
        if !didSend {
            onFailure(.sendFailed)
        }
        for waiter in waiters {
            waiter.resume()
        }
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
