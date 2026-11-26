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

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func resolve(host: String) async -> [IrxTunnelIPAddress] {
        await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            hints.ai_flags = AI_ADDRCONFIG
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var addresses: [IrxTunnelIPAddress] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor, addresses.count < 16 {
                if let sockaddr = info.pointee.ai_addr {
                    switch Int32(sockaddr.pointee.sa_family) {
                    case AF_INET:
                        sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                            var address = pointer.pointee.sin_addr
                            addresses.append(.v4(withUnsafeBytes(of: &address) { Array($0) }))
                        }
                    case AF_INET6:
                        sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                            var address = pointer.pointee.sin6_addr
                            addresses.append(.v6(withUnsafeBytes(of: &address) { Array($0) }))
                        }
                    default:
                        break
                    }
                }
                cursor = info.pointee.ai_next
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
final class IrxTunnelNWChannel: IrxTunnelByteChannel, @unchecked Sendable {
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
        tcp.connectionTimeout = max(1, Int(timeout.components.seconds))
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        let connection = NWConnection(host: host, port: port, using: parameters)
        let outcome = IrxTunnelConnectOutcome()
        // The deadline: whichever of state change, deadline, or cancellation
        // settles the outcome first wins; the others are no-ops.
        let deadline = Task {
            try? await sleep(timeout)
            outcome.finish(.failure(IrxTunnelOpenError(status: .timedOut)))
        }
        defer { deadline.cancel() }
        let result: Result<Void, IrxTunnelOpenError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, IrxTunnelOpenError>, Never>) in
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
            }
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
        while true {
            let chunk = try await receiveOnce(maximumByteCount: maximumByteCount)
            if chunk?.isEmpty != true { return chunk }
        }
    }

    private func receiveOnce(maximumByteCount: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func finishSending() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// Resumes the connect continuation exactly once, from whichever of state
/// change, timeout, or cancellation comes first.
private final class IrxTunnelConnectOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Void, IrxTunnelOpenError>, Never>?
    private var pending: Result<Void, IrxTunnelOpenError>?

    func install(_ continuation: CheckedContinuation<Result<Void, IrxTunnelOpenError>, Never>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Void, IrxTunnelOpenError>) {
        lock.lock()
        guard pending == nil else {
            lock.unlock()
            return
        }
        pending = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
