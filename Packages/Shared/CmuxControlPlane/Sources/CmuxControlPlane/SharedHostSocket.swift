import CmuxMobileWire
import Foundation

/// The one `ControlPlaneClient` behind a Mac's leases. It reads the client's
/// single-consumer streams once and fans them out: every lease gets the
/// current state then each change, every relayed signal, and every update of
/// the streams it subscribed. A stream subscribed by a second lease is
/// subscribed again on the socket, so the owner answers with a snapshot that
/// every subscriber applies (a snapshot always restores a mirror); a stream
/// is unsubscribed when its last subscriber leaves.
actor SharedHostSocket {
    private struct Sink<Element: Sendable> {
        let owner: UUID
        let continuation: AsyncStream<Element>.Continuation
    }

    private struct Fan {
        var sinks: [UUID: Sink<StreamUpdate>] = [:]
        var pump: Task<Void, Never>?
        /// The ticket of the socket subscription being read; older ones are ignored.
        var generation = 0
    }

    private let make: @Sendable () async throws -> ControlPlaneClient
    private var made: ControlPlaneClient?
    private var making: Task<ControlPlaneClient, any Error>?
    private var started = false
    private var closed = false
    private var state: ControlPlaneState = .idle
    private var stateSinks: [UUID: Sink<ControlPlaneState>] = [:]
    private var signalSinks: [UUID: Sink<SignalFrame>] = [:]
    private var fans: [String: Fan] = [:]
    private var pumps: [Task<Void, Never>] = []
    private var nextTicket = 0

    init(make: @escaping @Sendable () async throws -> ControlPlaneClient) {
        self.make = make
    }

    // MARK: Lifecycle

    /// Connects once; later calls return at once.
    func start() async {
        guard !started, !closed else { return }
        started = true
        do {
            let client = try await client()
            await client.start()
        } catch {
            publish(.failed(.unauthenticated))
        }
    }

    /// The client, made on first use (the install id is resolved then).
    func client() async throws -> ControlPlaneClient {
        if let made { return made }
        if closed { throw ControlPlaneError.stopped }
        if let making { return try await making.value }
        let task = Task { try await make() }
        making = task
        let client: ControlPlaneClient
        do {
            client = try await task.value
        } catch {
            making = nil
            throw error
        }
        making = nil
        if let made { return made }
        guard !closed else {
            await client.stop()
            throw ControlPlaneError.stopped
        }
        made = client
        attach(client)
        for name in fans.keys.sorted() { await resubscribe(name, on: client) }
        return client
    }

    /// Closes the socket and finishes every stream. Final.
    func shutdown() async {
        guard !closed else { return }
        closed = true
        making?.cancel()
        let client = made
        made = nil
        for pump in pumps { pump.cancel() }
        pumps = []
        for fan in fans.values { fan.pump?.cancel() }
        await client?.stop()
        for fan in fans.values { fan.sinks.values.forEach { $0.continuation.finish() } }
        fans = [:]
        stateSinks.values.forEach { $0.continuation.finish() }
        stateSinks = [:]
        signalSinks.values.forEach { $0.continuation.finish() }
        signalSinks = [:]
    }

    /// A lease left: its streams finish; streams nobody else reads are unsubscribed.
    func drop(owner: UUID) async {
        for (id, sink) in stateSinks where sink.owner == owner {
            sink.continuation.finish()
            stateSinks[id] = nil
        }
        for (id, sink) in signalSinks where sink.owner == owner {
            sink.continuation.finish()
            signalSinks[id] = nil
        }
        for stream in Array(fans.keys) {
            await unsubscribe(stream, owner: owner)
        }
    }

    // MARK: Fan-out

    func stateUpdates(owner: UUID) -> AsyncStream<ControlPlaneState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ControlPlaneState.self, bufferingPolicy: .bufferingNewest(8))
        guard !closed else {
            continuation.yield(.stopped)
            continuation.finish()
            return stream
        }
        let id = UUID()
        stateSinks[id] = Sink(owner: owner, continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeState(id) } }
        continuation.yield(state)
        return stream
    }

    func signalUpdates(owner: UUID) -> AsyncStream<SignalFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: SignalFrame.self, bufferingPolicy: .bufferingNewest(256))
        guard !closed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        signalSinks[id] = Sink(owner: owner, continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSignal(id) } }
        return stream
    }

    func subscribe(_ name: String, owner: UUID) async -> AsyncStream<StreamUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamUpdate.self, bufferingPolicy: .unbounded)
        guard !closed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        fans[name, default: Fan()].sinks[id] = Sink(owner: owner, continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id, of: name) } }
        if let made { await resubscribe(name, on: made) }
        return stream
    }

    func unsubscribe(_ name: String, owner: UUID) async {
        guard var fan = fans[name] else { return }
        for (id, sink) in fan.sinks where sink.owner == owner {
            sink.continuation.finish()
            fan.sinks[id] = nil
        }
        fans[name] = fan
        await unsubscribeIfUnread(name)
    }

    // MARK: Private

    private func attach(_ client: ControlPlaneClient) {
        let states = client.states
        let signals = client.signals
        pumps.append(Task { [weak self] in
            for await state in states { await self?.publish(state) }
        })
        pumps.append(Task { [weak self] in
            for await signal in signals { await self?.relay(signal) }
        })
    }

    /// Subscribes `name` on the socket (again): the owner sends a snapshot
    /// every subscriber receives, then contiguous events. The socket keeps one
    /// subscription per stream, so only the newest call's updates are read.
    private func resubscribe(_ name: String, on client: ControlPlaneClient) async {
        guard fans[name]?.sinks.isEmpty == false, !closed else { return }
        nextTicket += 1
        let ticket = nextTicket
        let updates = await client.subscribe(name)
        guard var fan = fans[name], !fan.sinks.isEmpty, !closed else {
            if fans[name] == nil, !closed { await client.unsubscribe(name) }
            return
        }
        guard ticket > fan.generation else { return }
        fan.generation = ticket
        fan.pump?.cancel()
        fan.pump = Task { [weak self] in
            for await update in updates { await self?.deliver(update, to: name, generation: ticket) }
        }
        fans[name] = fan
    }

    private func deliver(_ update: StreamUpdate, to name: String, generation: Int) {
        guard let fan = fans[name], fan.generation == generation else { return }
        for sink in fan.sinks.values { sink.continuation.yield(update) }
    }

    private func publish(_ next: ControlPlaneState) {
        state = next
        for sink in stateSinks.values { sink.continuation.yield(next) }
    }

    private func relay(_ signal: SignalFrame) {
        for sink in signalSinks.values { sink.continuation.yield(signal) }
    }

    private func removeState(_ id: UUID) { stateSinks[id] = nil }

    private func removeSignal(_ id: UUID) { signalSinks[id] = nil }

    private func removeSubscriber(_ id: UUID, of name: String) async {
        guard fans[name]?.sinks.removeValue(forKey: id) != nil else { return }
        await unsubscribeIfUnread(name)
    }

    private func unsubscribeIfUnread(_ name: String) async {
        guard let fan = fans[name], fan.sinks.isEmpty else { return }
        fan.pump?.cancel()
        fans[name] = nil
        await made?.unsubscribe(name)
    }
}
