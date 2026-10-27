import CmuxSafeConcurrency
import Darwin
public import Foundation
import Network

/// One outbound TCP connection the tunnel relays to. Every call suspends
/// until the operation is done, which is what bounds the relay's memory:
/// a relay never reads its next chunk before the previous one was sent.
public protocol IrxTunnelByteChannel: Sendable {
    /// The next chunk, or nil once the remote end finished sending.
    func receive(maximumByteCount: Int) async throws -> Data?
    func send(_ data: Data) async throws
    /// Half-close: no more bytes from us (TCP FIN).
    func finishSending() async
    /// Abort both directions.
    func cancel()
}

/// Opens outbound TCP connections from this Mac.
public protocol IrxTunnelConnecting: Sendable {
    /// Resolves a host name to addresses (no policy applied here).
    func resolve(host: String) async -> [IrxTunnelIPAddress]
    /// Connects to the first address that accepts, trying them in order.
    func connect(
        to addresses: [IrxTunnelIPAddress],
        port: Int,
        timeout: Duration
    ) async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel
}

/// Network.framework TCP. Addresses are always IP literals, so nothing here
/// resolves names, and system proxies are bypassed so the connection really
/// leaves from this Mac.
public struct IrxTunnelNetworkConnector: IrxTunnelConnecting {
    /// Waits out the connect deadline; injected so tests control time.
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter sleep: Defaults to `Task.sleep(for:)`. Not a closure-literal
    ///   default: see IrxPeerEngine.init (cx-bsue).
    public init(sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        // wakeup-allow: deadline of one TCP connect, cancelled when the connection settles
        self.sleep = sleep ?? { try await Task.sleep(for: $0, tolerance: IrxWakeLeeway(delay: $0).tolerance) }
    }

    public func resolve(host: String) async -> [IrxTunnelIPAddress] {
        await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            hints.ai_flags = AI_ADDRCONFIG
            var result: UnsafeMutablePointer<addrinfo>?
            // SAFETY: getaddrinfo reads the NUL-terminated copy of `host` and `hints` for
            // this call and stores the head of a list it allocates in `result`. The defer
            // below frees it once; the walk copies each address out before that.
            guard unsafe getaddrinfo(host, nil, &hints, &result) == 0, let first = unsafe result else { return [] }
            // SAFETY: frees the list getaddrinfo returned, exactly once.
            defer { unsafe freeaddrinfo(first) }
            var addresses: [IrxTunnelIPAddress] = []
            // SAFETY: the walk starts at the live list's head.
            var cursor: UnsafeMutablePointer<addrinfo>? = unsafe first
            // SAFETY: `cursor` is a node of the live list or nil, which ends the walk.
            while let info = unsafe cursor, addresses.count < 16 {
                // SAFETY: ai_next is the next node of the live list or nil.
                cursor = unsafe info.pointee.ai_next
                // SAFETY: ai_addr is nil or a sockaddr of ai_addrlen bytes inside the live list.
                guard let sockaddr = unsafe info.pointee.ai_addr else { continue }
                // SAFETY: sa_family is the first field of every sockaddr.
                let family = unsafe Int32(clamping: sockaddr.pointee.sa_family)
                switch family {
                case AF_INET:
                    // SAFETY: getaddrinfo gives AF_INET only to a sockaddr_in; the rebound
                    // view is read once, inside the closure, while the list is live.
                    let address = unsafe sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        unsafe $0.pointee.sin_addr
                    }
                    addresses.append(IrxTunnelIPAddress(kernel: address))
                case AF_INET6:
                    // SAFETY: as for AF_INET, with a sockaddr_in6.
                    let address = unsafe sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        unsafe $0.pointee.sin6_addr
                    }
                    addresses.append(IrxTunnelIPAddress(kernel: address))
                default:
                    break
                }
            }
            return addresses
        }.value
    }

    public func connect(
        to addresses: [IrxTunnelIPAddress],
        port: Int,
        timeout: Duration
    ) async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !addresses.isEmpty else {
            throw IrxTunnelOpenError(status: .denied)
        }
        let deadline = ContinuousClock.now + timeout
        var lastError = IrxTunnelOpenError(status: .failed)
        for address in addresses {
            let remaining = deadline - .now
            guard remaining > .zero else { throw IrxTunnelOpenError(status: .timedOut) }
            do {
                return try await IrxTunnelNWChannel.connect(
                    address: address, port: nwPort, timeout: remaining, sleep: sleep
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

/// An `NWConnection` behind async calls.
final class IrxTunnelNWChannel: IrxTunnelByteChannel {
    private let connection: NWConnection

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(
        address: IrxTunnelIPAddress,
        port: NWEndpoint.Port,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws(IrxTunnelOpenError) -> IrxTunnelNWChannel {
        let host: NWEndpoint.Host
        switch address {
        case .v4(let bytes):
            guard let v4 = IPv4Address(Data(bytes)) else { throw IrxTunnelOpenError(status: .failed) }
            host = .ipv4(v4)
        case .v6(let bytes):
            guard let v6 = IPv6Address(Data(bytes)) else { throw IrxTunnelOpenError(status: .failed) }
            host = .ipv6(v6)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(clamping: timeout.components.seconds))
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        let connection = NWConnection(host: host, port: port, using: parameters)
        let outcome = IrxTunnelConnectOutcome()
        // The deadline: whichever of state change, deadline, or cancellation
        // settles the outcome first wins; the others are no-ops.
        let deadline = Task {
            // wakeup-allow: deadline of the connect, cancelled when its state settles first
            try? await sleep(timeout)
            outcome.finish(.failure(IrxTunnelOpenError(status: .timedOut)))
        }
        defer { deadline.cancel() }
        let result: Result<Void, IrxTunnelOpenError> = await withTaskCancellationHandler {
            // A continuation dropped without a resume ends the connect as failed.
            (try? await withOnceContinuation { (continuation: OnceContinuation<Result<Void, IrxTunnelOpenError>, OnceContinuationError>) in
                outcome.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        outcome.finish(.success(()))
                    case .waiting(let error), .failed(let error):
                        // `.waiting` is Network.framework's retry loop (for
                        // example connection refused); a tunnel answers now.
                        outcome.finish(.failure(IrxTunnelOpenError(status: Self.status(for: error))))
                    case .cancelled:
                        outcome.finish(.failure(IrxTunnelOpenError(status: .failed)))
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "dev.cmux.irx.tunnel.tcp"))
            }) ?? .failure(IrxTunnelOpenError(status: .failed))
        } onCancel: {
            outcome.finish(.failure(IrxTunnelOpenError(status: .failed)))
        }
        switch result {
        case .success:
            connection.stateUpdateHandler = nil
            return IrxTunnelNWChannel(connection: connection)
        case .failure(let error):
            connection.stateUpdateHandler = nil
            connection.cancel()
            throw error
        }
    }

    static func status(for error: NWError) -> IrxTunnelOpenReply.Status {
        guard case .posix(let code) = error else { return .failed }
        switch code {
        case .ECONNREFUSED: return .refused
        case .EHOSTUNREACH, .EHOSTDOWN: return .hostUnreachable
        case .ENETUNREACH, .ENETDOWN: return .networkUnreachable
        case .ETIMEDOUT: return .timedOut
        default: return .failed
        }
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        // wakeup-allow: bounded each pass awaits one receive callback; data, EOF or an error ends it
        while true {
            let chunk = try await receiveOnce(maximumByteCount: maximumByteCount)
            if chunk?.isEmpty != true { return chunk }
        }
    }

    private func receiveOnce(maximumByteCount: Int) async throws -> Data? {
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximumByteCount)) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            })
        }
    }

    func finishSending() async {
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume(returning: ())
            })
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// Resumes the connect continuation exactly once, from whichever of state
/// change, timeout, or cancellation comes first.
final class IrxTunnelConnectOutcome: Sendable {
    private typealias Outcome = Result<Void, IrxTunnelOpenError>

    private struct State: Sendable {
        var continuation: OnceContinuation<Outcome, OnceContinuationError>?
        var pending: Outcome?
    }

    private let state = Mutex(State())

    func install(_ continuation: OnceContinuation<Result<Void, IrxTunnelOpenError>, OnceContinuationError>) {
        let pending: Outcome? = state.withLock { state in
            if let pending = state.pending { return pending }
            state.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(returning: pending)
        }
    }

    func finish(_ result: Result<Void, IrxTunnelOpenError>) {
        let continuation: OnceContinuation<Outcome, OnceContinuationError>? = state.withLock { state in
            guard state.pending == nil else { return nil }
            state.pending = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}
