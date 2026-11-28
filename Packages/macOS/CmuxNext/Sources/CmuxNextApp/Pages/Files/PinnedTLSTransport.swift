import Darwin
import Foundation
import Network

/// getaddrinfo off the main actor.
nonisolated struct SystemResolver: RemoteImageResolving {
    func resolve(_ host: String) async throws -> [IPAddress] {
        try await Self.lookup(host)
    }

    @concurrent private static func lookup(_ host: String) async throws -> [IPAddress] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw URLError(.cannotFindHost) }
        defer { freeaddrinfo(first) }
        var addresses: [IPAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let entry = node {
            if let raw = entry.pointee.ai_addr {
                switch Int32(raw.pointee.sa_family) {
                case AF_INET:
                    raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        var address = pointer.pointee.sin_addr
                        addresses.append(.v4(withUnsafeBytes(of: &address) { Array($0) }))
                    }
                case AF_INET6:
                    raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        var address = pointer.pointee.sin6_addr
                        addresses.append(.v6(withUnsafeBytes(of: &address) { Array($0) }))
                    }
                default:
                    break
                }
            }
            node = entry.pointee.ai_next
        }
        var seen: Set<IPAddress> = []
        return addresses.filter { seen.insert($0).inserted }
    }
}

/// HTTP/1.0 over TLS to one checked address (Network.framework): the connection goes to the IP
/// the fetch checked, never to a name, so no second DNS answer can change the target. TLS uses
/// the URL's host as the server name (SNI) and verifies the certificate against that name with
/// the system trust. No proxy (a proxy would resolve the name again), no cookie store, no
/// credentials. The body stops at `maximumBytes`; the whole request is bounded by
/// ``RemoteImagePolicy/timeout`` on the injected clock.
nonisolated struct PinnedTLSTransport: RemoteImageTransport {
    let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    nonisolated struct HTTPError: Error, Equatable {
        let reason: String
    }

    func send(_ request: RemoteImageRequest, maximumBytes: Int) async throws -> RemoteImageResponse {
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
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, request.host)
        let parameters = NWParameters(tls: tls)
        parameters.preferNoProxies = true
        let connection = NWConnection(host: host, port: port, using: parameters)
        let exchange = Exchange(connection: connection, reader: HTTPReplyReader(maximumBody: maximumBytes))
        let clock = clock
        // The deadline cancels the connection, which ends the exchange with an error.
        let deadline = Task {
            do { try await clock.sleep(for: RemoteImagePolicy.timeout) } catch { return } // wakeup-allow: bounded remote image fetch
            connection.cancel()
        }
        defer { deadline.cancel() }
        return try await exchange.run(Self.encode(request))
    }

    /// The request bytes: `GET <target> HTTP/1.0` and the request's headers only (with
    /// `Connection: close` and `Accept-Encoding: identity` the server may not chunk or compress).
    /// The reply is read by ``HTTPReplyReader`` (CFHTTPMessage).
    static func encode(_ request: RemoteImageRequest) -> Data {
        var text = "GET \(request.target) HTTP/1.0\r\n"
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
        private var reader: HTTPReplyReader
        private let queue = DispatchQueue(label: "com.cmuxterm.next.remote-image")
        // Queue-confined.
        private var continuation: CheckedContinuation<RemoteImageResponse, any Error>?

        init(connection: NWConnection, reader: HTTPReplyReader) {
            self.connection = connection
            self.reader = reader
        }

        func run(_ request: Data) async throws -> RemoteImageResponse {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    connection.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            self?.connection.send(content: request, completion: .contentProcessed { error in
                                if let error { self?.finish(.failure(error)) } else { self?.receive() }
                            })
                        case .failed(let error), .waiting(let error):
                            self?.finish(.failure(error))
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

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
                guard let self else { return }
                do {
                    if let content, try reader.append(content) { return finish(Result<RemoteImageResponse, any Error> { try reader.finish() }) }
                    if let error { return finish(.failure(error)) }
                    if complete { return finish(Result<RemoteImageResponse, any Error> { try reader.finish() }) }
                } catch {
                    return finish(.failure(error))
                }
                receive()
            }
        }

        private func finish(_ result: Result<RemoteImageResponse, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
