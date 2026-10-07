public import CmuxLink
import Foundation
import Network
import os

/// The host side of the direct carrier: listens, runs the Noise responder
/// for every connection and yields authenticated transports. B5 passes it to
/// `LinkHost(acceptor:)` with its paired-device trust store as `authorizer`.
public final class DirectAcceptor: LinkAcceptor {
    private struct State {
        var listener: NWListener?
        var handshakes: [UUID: Task<Void, Never>] = [:]
        var stopped = false
    }

    public let incoming: AsyncStream<any LinkTransport>
    public let hostID: String
    public let configuration: DirectListenConfiguration
    private let sink: AsyncStream<any LinkTransport>.Continuation
    private let handshake: DirectHandshake
    private let authorizer: any DirectAuthorizer
    private let injector: DirectFaultInjector?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "cmux.direct.acceptor")

    public convenience init(
        identity: DirectIdentity,
        hostID: String,
        configuration: DirectListenConfiguration = DirectListenConfiguration(),
        authorizer: any DirectAuthorizer
    ) {
        self.init(identity: identity, hostID: hostID, configuration: configuration, authorizer: authorizer, faultInjector: nil)
    }

    @_spi(Testing)
    public init(
        identity: DirectIdentity,
        hostID: String,
        configuration: DirectListenConfiguration,
        authorizer: any DirectAuthorizer,
        faultInjector: DirectFaultInjector?
    ) {
        (incoming, sink) = AsyncStream<any LinkTransport>.makeStream()
        self.hostID = hostID
        self.configuration = configuration
        handshake = DirectHandshake(identity: identity)
        self.authorizer = authorizer
        injector = faultInjector
    }

    /// Starts listening and returns the bound port once the listener is ready.
    public func start() async throws -> UInt16 {
        let parameters = DirectSocket.parameters()
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        if let localAddress = configuration.localAddress {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localAddress), port: port)
        }
        let listener: NWListener
        do {
            listener = configuration.localAddress == nil && configuration.port != 0
                ? try NWListener(using: parameters, on: port)
                : try NWListener(using: parameters)
        } catch {
            throw DirectAcceptError.listenerFailed("\(error)")
        }
        if let name = configuration.bonjourName {
            var txt = NWTXTRecord()
            txt["v"] = "1"
            txt["host"] = hostID
            listener.service = NWListener.Service(name: name, type: DirectEndpoint.serviceType, domain: nil, txtRecord: txt)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let started = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.listener = listener
            return true
        }
        guard started else { throw DirectAcceptError.listenerFailed("stopped") }
        let gate = OSAllocatedUnfairLock<CheckedContinuation<UInt16, any Error>?>(initialState: nil)
        return try await withCheckedThrowingContinuation { continuation in
            gate.withLock { $0 = continuation }
            listener.stateUpdateHandler = { [weak listener] newState in
                let result: Result<UInt16, DirectAcceptError>?
                switch newState {
                case .ready: result = .success(listener?.port?.rawValue ?? 0)
                case let .failed(error): result = .failure(.listenerFailed("\(error)"))
                case .cancelled: result = .failure(.listenerFailed("cancelled"))
                default: result = nil
                }
                guard let result, let waiter = gate.withLock({ value -> CheckedContinuation<UInt16, any Error>? in
                    defer { value = nil }
                    return value
                }) else { return }
                waiter.resume(with: result.mapError { $0 as any Error })
            }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and drops handshakes in progress. Live transports
    /// belong to `LinkHost`, which closes them.
    public func stop() async {
        let (listener, handshakes) = state.withLock { state -> (NWListener?, [Task<Void, Never>]) in
            state.stopped = true
            defer {
                state.listener = nil
                state.handshakes.removeAll()
            }
            return (state.listener, Array(state.handshakes.values))
        }
        listener?.cancel()
        for task in handshakes { task.cancel() }
        sink.finish()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let socket = DirectSocket(connection: connection)
        let timeout = configuration.handshakeTimeout
        let task = Task { [handshake, hostID, authorizer, injector, sink, state] in
            defer { _ = state.withLock { $0.handshakes.removeValue(forKey: id) } }
            do {
                let path = LinkPath(kind: injector?.currentPathKind ?? .direct, carrier: .direct)
                let transport = try await withTaskCancellationHandler {
                    try await withThrowingTaskGroup(of: DirectTransport?.self) { group in
                    group.addTask {
                        try await socket.start()
                        return try await handshake.accept(
                            socket: socket, hostID: hostID, authorizer: authorizer, path: path, injector: injector
                        )
                    }
                    group.addTask {
                        // A bounded deadline, not a sync wait: a connection that
                        // never finishes the handshake must not hold a task.
                        try await Task.sleep(for: timeout)
                        socket.cancel()
                        return nil
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next(), let transport = first else {
                        throw DirectAcceptError.handshakeTimedOut
                    }
                    return transport
                    }
                } onCancel: {
                    socket.cancel()
                }
                if case .terminated = sink.yield(transport) { await transport.close() }
            } catch {
                socket.cancel()
            }
        }
        let accepted = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.handshakes[id] = task
            return true
        }
        if !accepted { task.cancel() }
    }
}
