import CmuxSwiftRender
import Foundation

/// Supervises an out-of-process ``RenderInterpreterRunner`` worker and renders
/// untrusted sidebar source through it, so an interpreter crash, hang, or
/// runaway never takes down the host.
///
/// The host calls ``render(source:state:)``; the request is encoded and sent to
/// a worker process (the `cmux-sidebar-interpreter` executable), which replies
/// with a ``RenderNode``. If the worker crashes (its pipe closes) or fails to
/// answer within `timeout`, the call returns `nil` and the worker is relaunched
/// on the next render. Responses are correlated by id, so concurrent renders
/// are safe.
///
/// ```swift
/// let client = InterpreterClient(executableURL: workerURL)
/// let node = await client.render(source: source, state: dataContext)
/// // node == nil  ⇒  show the sidebar's error/empty state
/// ```
public actor InterpreterClient {
    /// Location of the worker executable (bundled in the app, injected in tests).
    nonisolated let executableURL: URL
    /// Extra environment for the worker process (used by tests for fault injection).
    nonisolated let extraEnvironment: [String: String]
    /// How long to wait for a single response before terminating the worker.
    nonisolated let timeout: Duration
    /// Arguments passed to the worker process (e.g. the worker-mode flag when
    /// re-executing the host app binary).
    nonisolated let arguments: [String]

    private var child: Child?
    private var generation: Int = 0
    private var nextID: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<InterpreterResponse?, Never>] = [:]

    /// Creates a client that launches `executableURL` on demand.
    ///
    /// - Parameters:
    ///   - executableURL: The worker binary to run.
    ///   - timeout: Per-render deadline; on expiry the worker is killed and the
    ///     render returns `nil`. Defaults to 2 seconds.
    ///   - arguments: Arguments for the worker process (defaults to none; the
    ///     re-exec-self factory passes the worker-mode flag).
    ///   - extraEnvironment: Additional environment for the worker process.
    public init(
        executableURL: URL,
        arguments: [String] = [],
        timeout: Duration = .seconds(2),
        environment extraEnvironment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.extraEnvironment = extraEnvironment
    }

    /// Renders `source` against `state` in the worker process.
    ///
    /// - Returns: the interpreted ``RenderNode``, or `nil` if the worker
    ///   produced no view, crashed, or timed out. Never throws and never
    ///   crashes the host regardless of what the source does.
    public func render(source: String, state: [String: SwiftValue]) async -> RenderNode? {
        let id = nextID
        nextID &+= 1
        let request = InterpreterRequest(id: id, source: source, state: state)
        guard let data = try? JSONEncoder().encode(request) else { return nil }

        let channel: LengthPrefixedMessageChannel
        do {
            channel = try ensureRunning()
        } catch {
            return nil
        }

        do {
            try channel.sendMessage(data)
        } catch {
            // Broken pipe: the worker died. Drop it; the next render relaunches.
            workerEnded(generation: generation)
            return nil
        }

        // Bounded, cancellable deadline: if no reply lands in `timeout`, fail
        // this waiter and terminate the worker (its closing pipe ends the
        // reader). This is a genuine timeout, not a poll/settle.
        let deadline = timeout
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self else { return }
            await self.timedOut(id: id)
        }
        defer { watchdog.cancel() }

        let response = await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }
        guard let response, response.id == id else { return nil }
        return response.node
    }

    /// Terminates the worker and fails any in-flight renders. Call from the
    /// owner's teardown (e.g. when the sidebar disappears).
    public func shutdown() {
        child?.process.terminate()
        child = nil
        failAllWaiters()
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
        child = Child(process: process, channel: channel, stdin: stdin, stdout: stdout)

        // Reader thread: blocks draining framed responses off the worker's
        // stdout descriptor and hands each to the actor. The channel is fd-
        // backed and Sendable; FileHandle is not, so we never capture it.
        let readChannel = channel
        let reader = Thread { [weak self] in
            while let data = readChannel.receiveMessage() {
                guard let response = try? JSONDecoder().decode(InterpreterResponse.self, from: data) else {
                    continue
                }
                Task { [weak self] in
                    guard let self else { return }
                    await self.deliver(response, generation: gen)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                await self.workerEnded(generation: gen)
            }
        }
        reader.stackSize = 1 << 20
        reader.name = "cmux-sidebar-interpreter-reader"
        reader.start()

        return channel
    }

    private func deliver(_ response: InterpreterResponse, generation gen: Int) {
        guard gen == generation else { return } // ignore a superseded worker
        waiters.removeValue(forKey: response.id)?.resume(returning: response)
    }

    private func timedOut(id: UInt64) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        // Discard the worker synchronously (not just terminate and wait for the
        // async termination handler) so the next render relaunches a fresh one
        // instead of reusing the dying process.
        discardWorker()
    }

    /// Terminates the current worker and forgets it, so ``ensureRunning()``
    /// relaunches on the next render. The old worker's reader/termination
    /// handler run under its now-stale generation and no-op.
    private func discardWorker() {
        child?.process.terminate()
        child = nil
    }

    private func workerEnded(generation gen: Int) {
        guard gen == generation else { return }
        child = nil
        failAllWaiters()
    }

    private func failAllWaiters() {
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume(returning: nil)
        }
    }
}

/// A running worker process and the channel/pipes that feed it. Held only by
/// the ``InterpreterClient`` actor, so its non-`Sendable` members are safe.
private struct Child {
    let process: Process
    let channel: LengthPrefixedMessageChannel
    let stdin: Pipe
    let stdout: Pipe
}
