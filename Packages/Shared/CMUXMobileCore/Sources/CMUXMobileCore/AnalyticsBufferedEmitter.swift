import Foundation

private final class AnalyticsFlushWaiter: @unchecked Sendable {
    // lint:allow lock - synchronous acknowledgement resolution closes the
    // cancellation race between the caller and the worker task.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resume() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class AnalyticsEmitterState: @unchecked Sendable {
    // lint:allow lock - nonisolated capture and flush calls need synchronous
    // bounded admission while the worker drains the control lane.
    private let lock = NSLock()
    private let capacity: Int
    private let wake: AsyncStream<Void>.Continuation
    private var commands: [BufferedAnalytics.Command] = []
    private var flushRequested = false
    private var drainRequested = false
    private var flushWaiters: [AnalyticsFlushWaiter] = []
    private var closed = false

    init(capacity: Int, wake: AsyncStream<Void>.Continuation) {
        self.capacity = max(1, capacity)
        self.wake = wake
    }

    func enqueue(_ command: BufferedAnalytics.Command) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        commands.append(command)
        let excess = commands.count - capacity
        if excess > 0 {
            commands.removeFirst(excess)
        }
        lock.unlock()
        _ = wake.yield(())
    }

    func requestFlush(_ waiter: AnalyticsFlushWaiter) -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            waiter.resume()
            return false
        }
        if flushWaiters.count >= capacity {
            // A caller that floods flush requests while a transport is
            // blocked must not turn control traffic into an unbounded queue.
            // The existing request will flush the shared pending buffer.
            lock.unlock()
            waiter.resume()
            return false
        }
        flushRequested = true
        flushWaiters.append(waiter)
        lock.unlock()
        _ = wake.yield(())
        return true
    }

    func requestDrain() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        drainRequested = true
        lock.unlock()
        _ = wake.yield(())
    }

    func takeWork() -> (
        commands: [BufferedAnalytics.Command],
        flushWaiters: [AnalyticsFlushWaiter],
        shouldDrain: Bool
    ) {
        lock.lock()
        let commands = self.commands
        self.commands.removeAll(keepingCapacity: true)
        let flushWaiters = flushRequested ? self.flushWaiters : []
        if flushRequested {
            flushRequested = false
            self.flushWaiters.removeAll(keepingCapacity: true)
        }
        let shouldDrain = drainRequested || !flushWaiters.isEmpty
        drainRequested = false
        lock.unlock()
        return (commands, flushWaiters, shouldDrain)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        commands.removeAll(keepingCapacity: false)
        let waiters = flushWaiters
        flushWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
        wake.finish()
    }
}

/// The result of handing one encoded analytics batch to the transport.
///
/// A transport owns HTTP status mapping (and can therefore keep that policy
/// out of the shared package). `retry` is for a transient failure, while
/// `drop` is for a permanent rejection. `offline` is kept explicit so a
/// transport can fail closed even when the reachability hint was stale.
public enum AnalyticsUploadResult: Sendable, Equatable {
    case accepted
    case retry
    case drop
    case offline
}

/// Sends already-encoded analytics batches to a concrete app transport.
///
/// The transport receives no event objects and has no access to the caller's
/// identity or properties. This keeps serialization and the privacy bounds in
/// `AnalyticsWireContract`, while allowing URLSession, a test double, or a
/// future authenticated proxy to be composed at the app boundary.
public protocol AnalyticsUploadTransport: Sendable {
    func upload(_ body: Data) async throws -> AnalyticsUploadResult
}

/// A bounded, asynchronous analytics emitter.
///
/// `capture`, `identify`, and `setSuperProperties` only enqueue a command on a
/// bounded `AsyncStream`; they never perform network or disk work on the
/// caller's thread. The worker batches validated wire events, checks
/// reachability before every attempt, and drops data when offline or when the
/// server reports a permanent failure. Retry delays are injected so tests can
/// advance them without sleeping, and cancellation propagates to the active
/// transport task.
///
/// This type is intentionally not installed by `AppContainer` yet. The app's
/// runtime default remains `NoopAnalytics` until consent and persistence
/// composition are reviewed together.
public final class BufferedAnalytics: AnalyticsEmitting, @unchecked Sendable {
    fileprivate enum Command: Sendable {
        case capture(String, [String: AnalyticsValue])
        case identify(String?, String?, [String: AnalyticsValue])
        case setSuperProperties([String: AnalyticsValue])
    }

    private let state: AnalyticsEmitterState
    private let workerTask: Task<Void, Never>

    /// Creates an emitter with bounded buffering and transport-independent
    /// retry policy.
    ///
    /// - Parameters:
    ///   - transport: The concrete uploader. It is never called while
    ///     `isReachable` returns `false`.
    ///   - isReachable: A synchronous, injected reachability hint. A false
    ///     value fails closed and discards queued events.
    ///   - queueCapacity: Maximum number of commands retained by the stream.
    ///     When full, the oldest command is dropped in favor of the newest.
    ///   - maxBatchEvents: Per-request event limit. It is clamped to the wire
    ///     contract's limit.
    ///   - maxRequestBytes: Per-request encoded body limit. It is clamped to
    ///     the wire contract's limit.
    ///   - batchingInterval: One-shot delay after the first pending event.
    ///     `flush()` bypasses this delay. A zero value schedules an immediate
    ///     asynchronous drain, which still allows a burst of captures to form
    ///     one batch.
    ///   - maxRetries: Number of retries after the initial transient attempt.
    ///   - retryBaseDelay: Initial retry delay. Delays grow exponentially and
    ///     are capped by `retryMaxDelay`.
    ///   - retryMaxDelay: Upper bound for one retry delay.
    ///   - sleep: Injected retry delay function. The default uses cancellable
    ///     `Task.sleep` and never polls. Batching cadence always uses the same
    ///     cancellable default clock so cancelling a flush cannot leave a test
    ///     backoff hook with an unrelated cadence delay.
    public init(
        transport: any AnalyticsUploadTransport,
        isReachable: @escaping @Sendable () -> Bool,
        queueCapacity: Int = 256,
        maxBatchEvents: Int = AnalyticsWireContract.maxBatchEvents,
        maxRequestBytes: Int = AnalyticsWireContract.maxRequestBytes,
        batchingInterval: TimeInterval = 1,
        maxRetries: Int = 3,
        retryBaseDelay: TimeInterval = 0.5,
        retryMaxDelay: TimeInterval = 30,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = BufferedAnalytics.defaultSleep
    ) {
        let commandCapacity = max(1, queueCapacity)
        let eventLimit = min(
            AnalyticsWireContract.maxBatchEvents,
            max(1, maxBatchEvents)
        )
        let bodyLimit = min(
            AnalyticsWireContract.maxRequestBytes,
            max(1, maxRequestBytes)
        )
        let interval = batchingInterval.isFinite ? max(0, batchingInterval) : 0
        let retries = max(0, maxRetries)
        let baseDelay = retryBaseDelay.isFinite ? max(0, retryBaseDelay) : 0
        let maximumDelay = retryMaxDelay.isFinite ? max(baseDelay, retryMaxDelay) : baseDelay
        let (wakeStream, wakeContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let state = AnalyticsEmitterState(capacity: commandCapacity, wake: wakeContinuation)
        self.state = state
        workerTask = Task {
            await BufferedAnalytics.run(
                wakeStream: wakeStream,
                state: state,
                transport: transport,
                isReachable: isReachable,
                maxBatchEvents: eventLimit,
                maxRequestBytes: bodyLimit,
                queueCapacity: commandCapacity,
                batchingInterval: interval,
                maxRetries: retries,
                retryBaseDelay: baseDelay,
                retryMaxDelay: maximumDelay,
                sleep: sleep
            )
        }
    }

    deinit {
        state.close()
        workerTask.cancel()
    }

    public func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        guard AnalyticsWireContract.allowedEventNames.contains(event),
              event.utf8.count <= AnalyticsWireContract.maxIdentifierBytes,
              let properties = Self.validInputProperties(properties)
        else { return }
        state.enqueue(.capture(event, properties))
    }

    public func identify(
        userId: String?,
        alias: String?,
        properties: [String: AnalyticsValue]
    ) {
        guard Self.validIdentifier(userId), Self.validIdentifier(alias),
              let properties = Self.validInputProperties(properties)
        else { return }
        state.enqueue(.identify(userId, alias, properties))
    }

    public func setSuperProperties(_ properties: [String: AnalyticsValue]) {
        guard let properties = Self.validInputProperties(properties) else { return }
        state.enqueue(.setSuperProperties(properties))
    }

    public func flush() async {
        let waiter = AnalyticsFlushWaiter()
        guard state.requestFlush(waiter) else { return }
        await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            // Cancelling one caller must not cancel the shared uploader. The
            // waiter is idempotent and the worker will ignore the second
            // resume when it completes the batch.
            waiter.resume()
        }
    }

    /// Stops the worker, cancels an in-flight transport call, and drops all
    /// pending events. A new emitter should be composed after cancellation.
    public func cancel() {
        state.close()
        workerTask.cancel()
    }

    public static let defaultSleep: @Sendable (TimeInterval) async -> Void = { delay in
        guard delay.isFinite, delay > 0 else { return }
        let maximumDelay = TimeInterval(UInt64.max - 1) / 1_000_000_000
        let nanoseconds = UInt64(min(delay, maximumDelay) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            // Cancellation is the intended wake-up path.
        }
    }

    private static func validIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= AnalyticsWireContract.maxIdentifierBytes
    }

    private static func validInputProperties(
        _ properties: [String: AnalyticsValue]
    ) -> [String: AnalyticsValue]? {
        guard properties.count <= AnalyticsWireContract.maxEventProperties else { return nil }
        var valid: [String: AnalyticsValue] = [:]
        valid.reserveCapacity(properties.count)
        for (key, value) in properties {
            let probe = AnalyticsWireEvent(name: "ios_app_launched", properties: [key: value])
            guard (try? AnalyticsWireContract.validate(probe)) != nil else { return nil }
            valid[key] = value
        }
        return valid
    }

    private static func run(
        wakeStream: AsyncStream<Void>,
        state: AnalyticsEmitterState,
        transport: any AnalyticsUploadTransport,
        isReachable: @escaping @Sendable () -> Bool,
        maxBatchEvents: Int,
        maxRequestBytes: Int,
        queueCapacity: Int,
        batchingInterval: TimeInterval,
        maxRetries: Int,
        retryBaseDelay: TimeInterval,
        retryMaxDelay: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) async {
        var pending: [AnalyticsWireEvent] = []
        var superProperties: [String: AnalyticsValue] = [:]
        var userID: String?
        var drainTask: Task<Void, Never>?
        var suppressAutomaticDrain = false
        var wakeIterator = wakeStream.makeAsyncIterator()

        func scheduleDrain() {
            guard drainTask == nil else { return }
            drainTask = Task {
                await BufferedAnalytics.defaultSleep(batchingInterval)
                guard !Task.isCancelled else { return }
                state.requestDrain()
            }
        }

        func append(_ event: AnalyticsWireEvent) {
            guard (try? AnalyticsWireContract.validate(event)) != nil else {
                return
            }
            pending.append(event)
            let excess = pending.count - queueCapacity
            if excess > 0 {
                pending.removeFirst(excess)
            }
            if !suppressAutomaticDrain {
                scheduleDrain()
            }
        }

        func eventProperties(_ properties: [String: AnalyticsValue]) -> [String: AnalyticsValue] {
            var merged = superProperties
            for (key, value) in properties {
                merged[key] = value
            }
            return merged
        }

        func validProperties(_ properties: [String: AnalyticsValue]) -> [String: AnalyticsValue] {
            var valid: [String: AnalyticsValue] = [:]
            for key in properties.keys.sorted() where valid.count < AnalyticsWireContract.maxEventProperties {
                guard let value = properties[key] else { continue }
                let probe = AnalyticsWireEvent(name: "ios_app_launched", properties: [key: value])
                guard (try? AnalyticsWireContract.validate(probe)) != nil else { continue }
                valid[key] = value
            }
            return valid
        }

        func nextBatch() -> (events: [AnalyticsWireEvent], data: Data)? {
            while !pending.isEmpty {
                var events: [AnalyticsWireEvent] = []
                var data: Data?
                var index = 0

                while index < pending.count, events.count < maxBatchEvents {
                    let candidate = events + [pending[index]]
                    do {
                        let candidateData = try AnalyticsWireBatch(events: candidate).encodedData()
                        guard candidateData.count <= maxRequestBytes else {
                            throw AnalyticsWireError.requestTooLarge(candidateData.count)
                        }
                        events = candidate
                        data = candidateData
                        index += 1
                    } catch {
                        if events.isEmpty {
                            // This event cannot be accepted even by itself.
                            pending.removeFirst()
                        }
                        break
                    }
                }

                if let data, !events.isEmpty {
                    return (events, data)
                }
            }
            return nil
        }

        func dropAllPending() {
            pending.removeAll(keepingCapacity: true)
        }

        func drain() async {
            guard !pending.isEmpty else { return }
            guard isReachable() else {
                // Analytics is best-effort. Never retain or transmit events
                // after an offline check fails.
                dropAllPending()
                return
            }

            while !pending.isEmpty {
                guard !Task.isCancelled else {
                    dropAllPending()
                    return
                }
                guard let batch = nextBatch() else { return }
                var attempt = 0
                var finished = false

                while !finished {
                    guard !Task.isCancelled else {
                        dropAllPending()
                        return
                    }
                    guard isReachable() else {
                        dropAllPending()
                        return
                    }
                    let result: AnalyticsUploadResult
                    do {
                        result = try await transport.upload(batch.data)
                    } catch is CancellationError {
                        dropAllPending()
                        return
                    } catch {
                        result = .retry
                    }

                    switch result {
                    case .accepted, .drop:
                        pending.removeFirst(min(batch.events.count, pending.count))
                        finished = true
                    case .offline:
                        dropAllPending()
                        finished = true
                    case .retry:
                        guard attempt < maxRetries else {
                            pending.removeFirst(min(batch.events.count, pending.count))
                            finished = true
                            break
                        }
                        let exponent = min(attempt, 30)
                        let multiplier = pow(2, Double(exponent))
                        let delay = min(retryMaxDelay, retryBaseDelay * multiplier)
                        attempt += 1
                        await sleep(delay)
                    }
                }
            }
        }

        defer {
            drainTask?.cancel()
            dropAllPending()
            state.close()
        }

        while !Task.isCancelled, let _ = await wakeIterator.next() {
            let work = state.takeWork()
            if work.shouldDrain {
                drainTask?.cancel()
                drainTask = nil
            }
            suppressAutomaticDrain = work.shouldDrain
            for command in work.commands {
                switch command {
                case let .capture(name, properties):
                    append(
                        AnalyticsWireEvent(
                            name: name,
                            properties: eventProperties(properties),
                            distinctID: userID
                        )
                    )
                case let .identify(newUserID, alias, properties):
                    let event = AnalyticsWireEvent(
                        name: "$identify",
                        properties: eventProperties(properties),
                        distinctID: newUserID,
                        anonymousID: alias
                    )
                    guard (try? AnalyticsWireContract.validate(event)) != nil else { continue }
                    userID = newUserID
                    append(event)
                case let .setSuperProperties(properties):
                    for (key, value) in validProperties(properties) {
                        superProperties[key] = value
                    }
                    if superProperties.count > AnalyticsWireContract.maxEventProperties {
                        let retainedKeys = superProperties.keys.sorted().prefix(
                            AnalyticsWireContract.maxEventProperties
                        )
                        superProperties = retainedKeys.reduce(into: [:]) { result, key in
                            result[key] = superProperties[key]
                        }
                    }
                }
            }
            suppressAutomaticDrain = false
            if work.shouldDrain {
                await drain()
            }
            if !work.flushWaiters.isEmpty {
                for waiter in work.flushWaiters {
                    waiter.resume()
                }
            }
        }
    }
}

/// A descriptive alias for callers that prefer the uploader-oriented name.
public typealias AnalyticsUploader = BufferedAnalytics
