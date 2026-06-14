import CmuxSwiftRender
import Foundation

/// Supervises an out-of-process sidebar **render** worker and relays the
/// host's scene/geometry/pointer traffic to it, so neither an interpreter
/// fault nor a renderer fault from untrusted sidebar source can crash the
/// host.
///
/// Unlike ``InterpreterClient`` (request/response, returns a `RenderNode` the
/// host renders), the render worker interprets *and renders* the file in its
/// own process and shares the resulting layer tree with the window server;
/// the host only ever receives the remote context id and ``ButtonAction``
/// values via ``events``.
///
/// Supervision model:
/// - The worker spawns lazily on the first send and is reused.
/// - On spawn, the cached last geometry and scene are replayed, so a crashed
///   worker comes back showing the current sidebar without host involvement.
/// - Every scene carries a sequence number the worker acks after committing;
///   if an ack misses the deadline the worker is presumed hung and discarded
///   (the next send relaunches it).
/// - A worker death (EOF on its pipe) just drops the child; the host's
///   periodic scene updates relaunch it within a tick.
public actor RenderWorkerClient {
    /// Location of the worker executable (the app re-executes its own binary).
    nonisolated let executableURL: URL
    /// Arguments for the worker process (the render-worker mode flag).
    nonisolated let arguments: [String]
    /// Extra environment for the worker process (used by tests for fault injection).
    nonisolated let extraEnvironment: [String: String]
    /// Optional cache key for owners that reuse a client only for one source.
    public nonisolated let sourceKey: String?
    /// How long to wait for a scene ack before declaring the worker hung.
    nonisolated let ackTimeout: Duration
    /// Synchronously readable mirror of the live worker's context id, so a
    /// remounting sidebar surface can adopt the layer without an async hop.
    public nonisolated let contextCache = RemoteContextCache()

    private var subscribers: [Int: AsyncStream<RenderWorkerEvent>.Continuation] = [:]
    private var nextSubscriberID = 0
    /// The live worker's announced context id, replayed to late subscribers so
    /// a remounted sidebar surface picks the layer back up immediately.
    private var currentContextId: UInt32?

    private var child: RenderChild?
    private var generation = 0
    private var nextSceneSeq: UInt64 = 1
    /// Highest scene seq we are still waiting on an ack for, with its watchdog.
    private var pendingAckSeq: UInt64?
    private var ackWatchdog: Task<Void, Never>?
    /// Replayed on every (re)spawn so the worker can rebuild the current view.
    private var lastScene: RenderScene?
    private var lastGeometry: RenderSurfaceGeometry?

    /// Creates a client that launches `executableURL` on demand.
    ///
    /// - Parameters:
    ///   - executableURL: The worker binary to run.
    ///   - arguments: Arguments for the worker process (the re-exec-self
    ///     factory passes the render-worker mode flag).
    ///   - sourceKey: Optional owner-defined key for cache/substitution checks.
    ///   - ackTimeout: Deadline for a scene ack before the worker is treated
    ///     as hung and discarded. Defaults to 3 seconds.
    ///   - extraEnvironment: Additional environment for the worker process.
    public init(
        executableURL: URL,
        arguments: [String] = [],
        sourceKey: String? = nil,
        ackTimeout: Duration = .seconds(3),
        environment extraEnvironment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.sourceKey = sourceKey
        self.ackTimeout = ackTimeout
        self.extraEnvironment = extraEnvironment
    }

    /// Subscribes to context announcements and button actions.
    ///
    /// Each call returns an independent stream, so sidebar surfaces can come
    /// and go (SwiftUI remounts on provider/file switches) without tearing
    /// down event delivery for everyone else. A new subscriber immediately
    /// receives the live worker's current context id, if any.
    public func subscribe() -> AsyncStream<RenderWorkerEvent> {
        let id = nextSubscriberID
        nextSubscriberID += 1
        let (stream, continuation) = AsyncStream.makeStream(of: RenderWorkerEvent.self)
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.unsubscribe(id) }
        }
        subscribers[id] = continuation
        if let currentContextId {
            continuation.yield(.context(currentContextId))
        }
        return stream
    }

    private func unsubscribe(_ id: Int) {
        subscribers.removeValue(forKey: id)
    }

    private func broadcast(_ event: RenderWorkerEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// Sends the current scene (file + data context + insets) to the worker,
    /// spawning or respawning it if needed. Never throws and never blocks on
    /// the worker: a dead pipe just drops the child for the next send.
    public func updateScene(
        filePath: String,
        state: [String: SwiftValue],
        topInset: Double,
        bottomInset: Double
    ) {
        let scene = RenderScene(
            seq: nextSceneSeq,
            filePath: filePath,
            state: state,
            topInset: topInset,
            bottomInset: bottomInset
        )
        nextSceneSeq &+= 1
        lastScene = scene
        send(.scene(scene))
        armAckWatchdog(for: scene.seq)
    }

    /// Tells the worker the host surface's size or backing scale changed.
    public func resize(_ geometry: RenderSurfaceGeometry) {
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        send(.resize(geometry))
    }

    /// Forwards a pointer interaction to be replayed in the worker.
    public func forward(_ event: RenderPointerEvent) {
        send(.pointer(event))
    }

    /// Forwards an explicit reload request (host notifications don't cross
    /// the process boundary).
    public func requestReload(names: [String]?) {
        send(.reloadSidebars(names))
    }

    /// Terminates the worker. The next send relaunches it. Call from the
    /// owner's teardown (e.g. when the sidebar disappears).
    public func shutdown() {
        discardWorker()
    }

    // MARK: - Sending

    private func send(_ message: RenderWorkerInbound) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        // One retry: a worker that died since the last send surfaces here as a
        // broken pipe (its Process may still read as running before the
        // termination handler lands), so relaunch once and re-deliver instead
        // of dropping the message until the next tick.
        for _ in 0..<2 {
            let channel: LengthPrefixedMessageChannel
            do {
                channel = try ensureRunning()
            } catch {
                return
            }
            do {
                try channel.sendMessage(data)
                return
            } catch {
                discardWorker()
            }
        }
    }

    /// Arms (or extends) the hang watchdog for `seq`.
    ///
    /// Bounded, cancellable deadline (mirrors ``InterpreterClient``'s render
    /// watchdog): if the worker hasn't acked by `ackTimeout` it is hung —
    /// discard it so the next scene update relaunches a fresh one. Cancelled
    /// by the matching ack; not a poll.
    private func armAckWatchdog(for seq: UInt64) {
        pendingAckSeq = seq
        guard ackWatchdog == nil else { return } // oldest deadline stands
        ackWatchdog = Task { [weak self, ackTimeout] in
            try? await Task.sleep(for: ackTimeout)
            guard !Task.isCancelled, let self else { return }
            await self.ackDeadlineExpired()
        }
    }

    private func ackDeadlineExpired() {
        ackWatchdog = nil
        guard pendingAckSeq != nil else { return }
        pendingAckSeq = nil
        discardWorker()
    }

    private func acked(_ seq: UInt64, generation gen: Int) {
        guard gen == generation else { return }
        guard let pending = pendingAckSeq, seq >= pending else { return }
        pendingAckSeq = nil
        ackWatchdog?.cancel()
        ackWatchdog = nil
    }

    // MARK: - Worker lifecycle

    private func ensureRunning() throws -> LengthPrefixedMessageChannel {
        if let child, child.process.isRunning {
            return child.channel
        }
        return try launch()
    }

    private func launch() throws -> LengthPrefixedMessageChannel {
        generation &+= 1
        let gen = generation
        pendingAckSeq = nil
        ackWatchdog?.cancel()
        ackWatchdog = nil

        let process = Process()
        process.executableURL = executableURL
        if !arguments.isEmpty { process.arguments = arguments }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        if !extraEnvironment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(extraEnvironment) { _, new in new }
        }

        let channel = LengthPrefixedMessageChannel(
            readFD: stdout.fileHandleForReading.fileDescriptor,
            writeFD: stdin.fileHandleForWriting.fileDescriptor
        )
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.workerEnded(generation: gen) }
        }

        try process.run()
        child = RenderChild(process: process, channel: channel, stdin: stdin, stdout: stdout)

        // Reader thread: blocks draining framed worker messages off the
        // worker's stdout descriptor and hands each to the actor. The channel
        // is fd-backed and Sendable; FileHandle is not, so we never capture
        // it. (Same justified pattern as InterpreterClient's reader.)
        let readChannel = channel
        let reader = Thread { [weak self] in
            let decoder = JSONDecoder()
            while let data = readChannel.receiveMessage() {
                guard let message = try? decoder.decode(RenderWorkerOutbound.self, from: data) else {
                    continue
                }
                Task { [weak self] in
                    guard let self else { return }
                    await self.deliver(message, generation: gen)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                await self.workerEnded(generation: gen)
            }
        }
        reader.stackSize = 1 << 20
        reader.name = "cmux-sidebar-render-reader"
        reader.start()

        // Replay the current state so a respawned worker rebuilds the sidebar
        // without the host having to notice the crash.
        if let lastGeometry, let data = try? JSONEncoder().encode(RenderWorkerInbound.resize(lastGeometry)) {
            try? channel.sendMessage(data)
        }
        if let lastScene, let data = try? JSONEncoder().encode(RenderWorkerInbound.scene(lastScene)) {
            try? channel.sendMessage(data)
            armAckWatchdog(for: lastScene.seq)
        }

        return channel
    }

    private func deliver(_ message: RenderWorkerOutbound, generation gen: Int) {
        guard gen == generation else { return } // ignore a superseded worker
        switch message {
        case let .context(contextId):
            currentContextId = contextId
            Task { @MainActor [contextCache] in contextCache.contextId = contextId }
            broadcast(.context(contextId))
        case let .ack(seq):
            acked(seq, generation: gen)
        case let .action(action):
            broadcast(.action(action))
        }
    }

    /// Terminates the current worker and forgets it, so the next send
    /// relaunches a fresh one. The old worker's reader/termination handler
    /// run under its now-stale generation and no-op.
    private func discardWorker() {
        child?.process.terminate()
        child = nil
        ackWatchdog?.cancel()
        ackWatchdog = nil
        pendingAckSeq = nil
        currentContextId = nil // the layer died with the worker
        Task { @MainActor [contextCache] in contextCache.contextId = nil }
    }

    private func workerEnded(generation gen: Int) {
        guard gen == generation else { return }
        child = nil
        ackWatchdog?.cancel()
        ackWatchdog = nil
        pendingAckSeq = nil
        currentContextId = nil // the layer died with the worker
        Task { @MainActor [contextCache] in contextCache.contextId = nil }
    }
}

/// A running render worker process and the channel/pipes that feed it. Held
/// only by the ``RenderWorkerClient`` actor, so its non-`Sendable` members are
/// safe. (Named distinctly from ``InterpreterClient``'s file-private `Child`.)
private struct RenderChild {
    let process: Process
    let channel: LengthPrefixedMessageChannel
    let stdin: Pipe
    let stdout: Pipe
}
