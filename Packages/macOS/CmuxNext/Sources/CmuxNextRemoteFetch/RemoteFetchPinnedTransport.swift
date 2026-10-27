#if canImport(Network)
import Foundation
import Network
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// HTTP/1.1 over TLS to one checked address (Network.framework): the connection goes to the IP
/// the fetch checked, never to a name, so no second DNS answer can change the target (a DNS
/// rebinding). TLS uses the URL's host as the server name (SNI) and verifies the certificate
/// against that name with the system trust. No proxy (a proxy would resolve the name again), no
/// cookie store, no credentials. The body stops at `maximumBytes`. Cancelling the calling task
/// cancels the connection; ``GuardedRemoteFetch`` owns the deadline.
public nonisolated struct PinnedTLSTransport: RemoteFetchTransport {
    /// How long one address may take to connect before the next checked address is tried.
    static let connectTimeoutSeconds = 4

    public init() {}

    nonisolated struct HTTPError: Error, Equatable {
        let reason: String
    }

    public func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
        let host: NWEndpoint.Host
        switch request.address {
        case .v4(let bytes):
            guard let address = IPv4Address(Data(bytes)) else { throw HTTPError(reason: "address") }
            host = .ipv4(address)
        case .v6(let bytes):
            guard let address = IPv6Address(Data(bytes)) else { throw HTTPError(reason: "address") }
            host = .ipv6(address)
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: request.port)) else { throw HTTPError(reason: "port") }
        let tls = NWProtocolTLS.Options()
        // SAFETY: the call reads the NUL-terminated copy of the host name made for it and copies the name into the
        // options.
        unsafe sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, request.host)
        // A silent address (often a broken IPv6 route) must fail fast, so the next checked address
        // gets its turn inside the fetch's deadline.
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Self.connectTimeoutSeconds
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        let connection = NWConnection(host: host, port: port, using: parameters)
        let exchange = Exchange(connection: connection, reader: RemoteFetchReplyReader(maximumBody: maximumBytes))
        let bytes = Self.encode(request)
        return try await withTaskCancellationHandler {
            try await exchange.run(bytes)
        } onCancel: {
            exchange.cancel()
        }
    }

    /// The request bytes: `GET <target> HTTP/1.1` and the request's headers only (`Host` and
    /// `Connection: close` among them, so the server ends the connection after one reply). The
    /// reply, chunked or compressed or not, is read by ``RemoteFetchReplyReader``.
    static func encode(_ request: RemoteFetchRequest) -> Data {
        var text = "GET \(request.target) HTTP/1.1\r\n"
        for name in request.headers.keys.sorted() {
            guard let value = request.headers[name], !value.contains("\r"), !value.contains("\n") else { continue }
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// One connection's request and its whole answer, on the connection's own queue.
    // crash-allow: every mutable member is touched only on `queue` (the connection's own queue); the class is shared only to hop onto it.
    nonisolated final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private var reader: RemoteFetchReplyReader
        // carve-out: NWConnection delivers its callbacks on a dispatch queue.
        private let queue = DispatchQueue(label: "com.cmuxterm.next.remote-fetch", qos: .userInitiated)
        // Queue-confined.
        private var continuation: OnceContinuation<RemoteFetchResponse, any Error>?
        private var cancelled = false
        private var ready = false

        init(connection: NWConnection, reader: RemoteFetchReplyReader) {
            self.connection = connection
            self.reader = reader
        }

        func run(_ request: Data) async throws -> RemoteFetchResponse {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<RemoteFetchResponse, any Error>) in
                queue.async { [self] in
                    guard !cancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    connection.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            self?.ready = true
                            self?.connection.send(content: request, completion: .contentProcessed { error in
                                if let error { self?.finish(.failure(error)) } else { self?.receive() }
                            })
                        case .failed(let error), .waiting(let error):
                            guard let self else { return }
                            finish(.failure(ready ? error : RemoteFetchConnectFailure(underlying: error)))
                        case .cancelled:
                            self?.finish(.failure(CancellationError()))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
        }

        func cancel() {
            queue.async { [self] in
                cancelled = true
                finish(.failure(CancellationError()))
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
                guard let self else { return }
                do {
                    if let content, try reader.append(content) { return finish(Result<RemoteFetchResponse, any Error> { try reader.finish() }) }
                    if let error { return finish(.failure(error)) }
                    if complete { return finish(Result<RemoteFetchResponse, any Error> { try reader.finish() }) }
                } catch {
                    return finish(.failure(error))
                }
                receive()
            }
        }

        private func finish(_ result: Result<RemoteFetchResponse, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}

extension GuardedRemoteFetch {
    /// A guarded fetch over ``PinnedTLSTransport``, the system's TLS to each checked address.
    public init(maximumBytes: Int, timeout: Duration, accept: String, resolver: any RemoteAddressResolving,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.init(maximumBytes: maximumBytes, timeout: timeout, accept: accept, resolver: resolver,
                  transport: PinnedTLSTransport(), clock: clock)
    }
}
#endif
