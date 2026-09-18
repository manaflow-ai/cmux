/// Owns one packet-tunnel adapter and processes platform callbacks in arrival order.
///
/// NetworkExtension entrypoints submit synchronously to the stream; a single
/// consumer task calls ``run()``. This preserves start/stop ordering without
/// launching a separate, potentially reordered task for each callback.
public actor CloudTunnelProviderStartGate {
    /// Completes one platform start request with its actual outcome.
    public typealias Completion = @Sendable (CloudTunnelProviderError?) -> Void
    /// Completes one platform stop request after the adapter has stopped.
    public typealias StopCompletion = @Sendable () -> Void

    private enum Event: Sendable {
        case start(Result<String, CloudTunnelProviderError>, Completion)
        case stop(StopCompletion)
        case started(UInt64, CloudTunnelProviderError?)
        case stopped(UInt64)
    }

    private enum State: String {
        case idle, starting, running, stopping, closed
    }

    private nonisolated let input: AsyncStream<Event>.Continuation
    private let events: AsyncStream<Event>
    private let adapter: any CloudTunnelAdapter
    private let diagnostic: @Sendable (String) -> Void
    private let didStop: StopCompletion
    private var consuming = false
    private var state = State.idle
    private var generation: UInt64 = 0
    private var configuration: String?
    private var starts: [Completion] = []
    private var stops: [StopCompletion] = []
    private var stopIssued = false

    /// Creates the lifecycle owner without starting a tunnel or a task.
    /// - Parameters:
    ///   - adapter: The platform adapter, called only by this actor's consumer.
    ///   - diagnostic: Receives lifecycle metadata only, never tunnel configuration.
    ///   - didStop: Runs after stop callbacks and queued events have been drained.
    public init(
        adapter: any CloudTunnelAdapter,
        diagnostic: @escaping @Sendable (String) -> Void = { _ in },
        didStop: @escaping StopCompletion = {}
    ) {
        let channel = AsyncStream<Event>.makeStream()
        input = channel.continuation
        events = channel.stream
        self.adapter = adapter
        self.diagnostic = diagnostic
        self.didStop = didStop
    }

    /// Enqueues a platform start without an asynchronous scheduling hop.
    /// - Parameters:
    ///   - configuration: The validated saved configuration or its validation error.
    ///   - completion: Called exactly once, including for duplicate or rejected starts.
    public nonisolated func start(
        configuration: Result<String, CloudTunnelProviderError>,
        completion: @escaping Completion
    ) {
        if case .terminated = input.yield(.start(configuration, completion)) {
            completion(.cancelled)
        }
    }

    /// Enqueues a stop; no replacement start is admitted into a retiring provider.
    /// - Parameter completion: Called after adapter teardown, or immediately if closed.
    public nonisolated func stop(completion: @escaping StopCompletion) {
        if case .terminated = input.yield(.stop(completion)) { completion() }
    }

    /// Runs the single ordered consumer until the provider stops or its owner cancels.
    public func run() async {
        guard !consuming else { return }
        consuming = true
        for await event in events { handle(event) }
        if state == .closed { didStop() }
    }

    private func handle(_ event: Event) {
        switch event {
        case let .start(result, completion):
            guard state != .stopping, state != .closed else {
                log("start.rejected stopping=true")
                completion(.cancelled)
                return
            }
            guard case let .success(config) = result else {
                if case let .failure(error) = result { completion(error) }
                return
            }
            switch state {
            case .idle:
                generation += 1
                configuration = config
                starts = [completion]
                state = .starting
                log("start.begin callbacks=1")
                let current = generation
                adapter.start(configuration: config) { [input] error in
                    input.yield(.started(current, error))
                }
            case .starting, .running:
                guard configuration == config else {
                    log("start.rejected configurationChanged=true")
                    completion(.configurationChanged)
                    return
                }
                if state == .running {
                    log("start.replay callbacks=1")
                    completion(nil)
                } else {
                    starts.append(completion)
                    log("start.coalesced callbacks=\(starts.count)")
                }
            case .stopping, .closed:
                break // Rejected above.
            }
        case let .stop(completion):
            if state == .closed { completion(); return }
            stops.append(completion)
            if state == .stopping { return }
            let wasStarting = state == .starting
            let wasIdle = state == .idle
            state = .stopping
            log("stop.begin duringStart=\(wasStarting) callbacks=\(stops.count)")
            // A stop cannot overtake an in-flight adapter start. Its completion
            // event schedules teardown, even if that start ultimately fails.
            if wasIdle { finishStop() }
            else if !wasStarting { issueStop() }
        case let .started(current, error):
            guard current == generation, state == .starting || state == .stopping else {
                log("start.stale callbackGeneration=\(current)")
                return
            }
            if state == .stopping {
                completeStarts(error: .cancelled)
                issueStop()
            } else {
                state = error == nil ? .running : .idle
                if error != nil { configuration = nil }
                completeStarts(error: error)
            }
        case let .stopped(current):
            guard current == generation, state == .stopping else { return }
            finishStop()
        }
    }

    private func completeStarts(error: CloudTunnelProviderError?) {
        let callbacks = starts
        starts = []
        log("start.finished success=\(error == nil) callbacks=\(callbacks.count)")
        callbacks.forEach { $0(error) }
    }

    private func issueStop() {
        guard !stopIssued else { return }
        stopIssued = true
        let current = generation
        adapter.stop { [input] in input.yield(.stopped(current)) }
    }

    private func finishStop() {
        state = .closed
        configuration = nil
        input.finish()
        let callbacks = stops
        stops = []
        log("stop.finished callbacks=\(callbacks.count)")
        callbacks.forEach { $0() }
    }

    private func log(_ event: String) {
        diagnostic("\(event) generation=\(generation) state=\(state.rawValue)")
    }
}
