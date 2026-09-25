public import Foundation
public import Network

/// Accepts Direct QUIC connections on one UDP port and yields each carrier
/// after its dialer proved an Ed25519 device key. Admission (who that key
/// belongs to and whether it may connect) stays with the irx server.
public final class DirectQuicListener: @unchecked Sendable {
    /// Unauthenticated connections allowed to be mid-handshake at once.
    static let maximumPendingHandshakes = 16

    private let listener: NWListener
    private let identity: IrxIdentity
    private let handshakeDeadline: Duration
    private let queue = DispatchQueue(label: "cmux.direct-quic.listener")
    private let lock = NSLock()
    private var pendingHandshakes = 0
    private var readyWaiter: CheckedContinuation<UInt16, any Error>?
    private var readyPort: UInt16?
    private var failure: (any Error)?
    private let continuation: AsyncStream<DirectQuicCarrierConnection>.Continuation

    /// Authenticated carriers, in arrival order. Ends when the listener stops.
    public let connections: AsyncStream<DirectQuicCarrierConnection>

    /// Binds `port` on every interface. Throws when this OS cannot load the
    /// in-memory TLS identity (macOS 14) or the port cannot be used.
    public init(
        port: UInt16,
        identity: IrxIdentity,
        handshakeDeadline: Duration = .seconds(5)
    ) throws {
        guard let tlsIdentity = DirectQuicTLSIdentity.load(),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DirectQuicError.listenerUnavailable
        }
        let options = DirectQuicCarrierConnection.makeOptions()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, tlsIdentity)
        let parameters = NWParameters(quic: options)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: nwPort)
        self.identity = identity
        self.handshakeDeadline = handshakeDeadline
        (connections, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        listener.newConnectionGroupHandler = { [weak self] group in
            self?.handshake(group)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resolved: Result<UInt16, any Error>? = lock.withLock {
                if let readyPort { return .success(readyPort) }
                if let failure { return .failure(failure) }
                readyWaiter = continuation
                return nil
            }
            if let resolved {
                continuation.resume(with: resolved)
            } else {
                listener.start(queue: queue)
            }
        }
    }

    public func cancel() {
        listener.cancel()
        continuation.finish()
    }

    private func stateChanged(_ state: NWListener.State) {
        let result: Result<UInt16, any Error>
        switch state {
        case .ready:
            result = .success(listener.port?.rawValue ?? 0)
        case let .failed(error):
            result = .failure(error)
        case .cancelled:
            result = .failure(DirectQuicError.listenerUnavailable)
        default:
            return
        }
        let waiter = lock.withLock { () -> CheckedContinuation<UInt16, any Error>? in
            switch result {
            case let .success(port): readyPort = port
            case let .failure(error): failure = error
            }
            defer { readyWaiter = nil }
            return readyWaiter
        }
        waiter?.resume(with: result)
        if case .failure = result { continuation.finish() }
    }

    private func handshake(_ group: NWConnectionGroup) {
        let admitted = lock.withLock { () -> Bool in
            guard pendingHandshakes < Self.maximumPendingHandshakes else { return false }
            pendingHandshakes += 1
            return true
        }
        guard admitted else {
            group.cancel()
            return
        }
        Task { [weak self, identity, handshakeDeadline] in
            let carrier = try? await DirectQuicCarrierConnection.accept(
                group: group, identity: identity, deadline: handshakeDeadline)
            guard let self else {
                carrier?.close(errorCode: 1, reason: IrxCloseCode.hostShutdown.reasonData)
                return
            }
            lock.withLock { pendingHandshakes -= 1 }
            guard let carrier else { return }
            if case .dropped = continuation.yield(carrier) {
                carrier.close(errorCode: 1, reason: IrxCloseCode.hostShutdown.reasonData)
            }
        }
    }
}
