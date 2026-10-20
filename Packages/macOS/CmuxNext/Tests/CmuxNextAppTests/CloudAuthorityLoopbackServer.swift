import Foundation
@preconcurrency import Network
@testable import CmuxNextCloud

/// Binds only127.0.0.1 and records the actual HTTP upgrade before scripted replies and real WebSocket frames.
actor CloudAuthorityLoopbackServer {
    enum Mode: Sendable { case upgrade, redirect(Int, URL?), refuse(Int, Bool) }
    private enum Event: Sendable { case ready(UInt16), failure(NWError), connection(NWConnection) }
    private var mode: Mode
    // Network requires a callback queue; it only delivers events into the actor-owned streams.
    private let queue = DispatchQueue(label: "cloud-authority-loopback")
    private let events = AsyncStream<Event>.makeStream()
    private let ready = AsyncThrowingStream<UInt16, any Error>.makeStream()
    private let requests = AsyncThrowingStream<(id: UUID, target: String, headers: [String: String]), any Error>.makeStream()
    private var listener: NWListener?
    private var listening: Task<Void, Never>?
    private var peers: [UUID: CloudAuthorityLoopbackConnection] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var readers: [CloudAuthorityLoopbackRead] = []
    private var stopped = false
    private var port: UInt16 = 0
    private(set) var accepted = 0
    private(set) var targets: [String] = []

    init(mode: Mode = .upgrade) { self.mode = mode }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let sink = events.continuation
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: if let port = listener?.port?.rawValue { sink.yield(.ready(port)) }
            case .failed(let error): sink.yield(.failure(error)); sink.finish()
            case .cancelled: sink.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { sink.yield(.connection($0)) }
        let stream = events.stream
        // task-owner: listening; stop joins it after the listener's cancelled event drains accepted connections.
        listening = Task { [weak self] in
            for await event in stream { await self?.receive(event) }
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        guard let port = try await iterator.next(), let url = URL(string: "http://127.0.0.1:\(port)") else { throw CancellationError() }
        return url
    }

    func setMode(_ mode: Mode) { self.mode = mode }

    func nextRequest() async throws -> (id: UUID, target: String, headers: [String: String]) {
        var iterator = requests.stream.makeAsyncIterator()
        guard let request = try await iterator.next() else { throw CancellationError() }
        return request
    }

    func peer(_ id: UUID) throws -> CloudAuthorityLoopbackConnection {
        guard let peer = peers[id] else { throw CancellationError() }
        return peer
    }

    func read(_ socket: any CloudAuthorityWireSocket) -> CloudAuthorityLoopbackRead {
        let reader = CloudAuthorityLoopbackRead(socket)
        readers.append(reader)
        return reader
    }

    func stop() async {
        stopped = true
        listener?.cancel()
        await listening?.value
        for reader in readers { await reader.stop() }
        for peer in peers.values { await peer.close() }
        for job in jobs.values { await job.value }
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        jobs.removeAll(); peers.removeAll(); readers.removeAll(); listening = nil; listener = nil
        requests.continuation.finish(); ready.continuation.finish()
    }

    private func receive(_ event: Event) {
        switch event {
        case .ready(let port): self.port = port; ready.continuation.yield(port); ready.continuation.finish()
        case .failure(let error):
            ready.continuation.finish(throwing: error); requests.continuation.finish(throwing: error)
        case .connection(let connection):
            accepted += 1
            guard !stopped else { connection.cancel(); return }
            let id = UUID(), peer = CloudAuthorityLoopbackConnection(connection, queue: queue)
            peers[id] = peer
            // task-owner: jobs; stop closes every connection and joins every accepted request.
            jobs[id] = Task { [weak self] in
                do {
                    let request = try await peer.request()
                    await self?.reply(id: id, request: request, peer: peer)
                } catch { await peer.close() }
            }
        }
    }

    private func reply(id: UUID, request: (target: String, headers: [String: String]), peer: CloudAuthorityLoopbackConnection) async {
        targets.append(request.target)
        requests.continuation.yield((id, request.target, request.headers))
        do {
            guard request.target.hasPrefix("/v1/wire/") else { try await peer.respond(status: 400); return }
            switch mode {
            case .upgrade: try await peer.upgrade(request.headers)
            case .redirect(let status, let destination):
                let target = destination?.absoluteString ?? "ws://127.0.0.1:\(port)/redirected"
                try await peer.respond(status: status, headers: ["Location": target])
            case .refuse(let status, let cookie):
                try await peer.respond(status: status, headers: cookie ? ["Set-Cookie": "cmux_observer=fixture; Path=/"] : [:])
            }
        } catch { await peer.close() }
    }
}
