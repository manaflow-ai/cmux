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

/// HTTP/1.1 over TLS to one checked address (Network.framework): the connection goes to the IP
/// the fetch checked, never to a name, so no second DNS answer can change the target. TLS uses
/// the URL's host as the server name (SNI) and verifies the certificate against that name with
/// the system trust. No proxy (a proxy would resolve the name again), no cookie store, no
/// credentials. The body stops at `maximumBytes`; the whole request is bounded by
/// ``RemoteImagePolicy/timeout`` on the injected clock.
nonisolated struct PinnedTLSTransport: RemoteImageTransport {
    /// The answer's headers may not exceed this.
    static let maximumHeaderBytes = 64 * 1024
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
        let exchange = Exchange(connection: connection, limit: maximumBytes + Self.maximumHeaderBytes)
        let clock = clock
        // The deadline cancels the connection, which ends the exchange with an error.
        let deadline = Task {
            do { try await clock.sleep(for: RemoteImagePolicy.timeout) } catch { return } // wakeup-allow: bounded remote image fetch
            connection.cancel()
        }
        defer { deadline.cancel() }
        let raw = try await exchange.run(Self.encode(request))
        return try Self.parse(raw, maximumBytes: maximumBytes)
    }

    /// The request bytes: `GET <target> HTTP/1.1` and the request's headers only.
    static func encode(_ request: RemoteImageRequest) -> Data {
        var text = "GET \(request.target) HTTP/1.1\r\n"
        for name in request.headers.keys.sorted() {
            guard let value = request.headers[name], !value.contains("\r"), !value.contains("\n") else { continue }
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// Parses a whole HTTP/1.1 answer (the connection closed after it): status, headers, and a
    /// Content-Length, chunked or read-to-close body. A body past `maximumBytes` throws.
    static func parse(_ raw: Data, maximumBytes: Int) throws -> RemoteImageResponse {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { throw HTTPError(reason: "headers") }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else {
            throw HTTPError(reason: "status")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        if let encoding = headers["content-encoding"], encoding.lowercased() != "identity" { throw HTTPError(reason: "encoding") }
        var body = Data(raw[end.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(body, maximumBytes: maximumBytes)
        } else if let length = headers["content-length"].flatMap(Int.init) {
            guard length <= maximumBytes, body.count >= length else { throw HTTPError(reason: "length") }
            body = body.prefix(length)
        }
        guard body.count <= maximumBytes else { throw HTTPError(reason: "too large") }
        return RemoteImageResponse(status: status, headers: headers, body: body)
    }

    /// Whether `raw` holds a whole answer (headers and a Content-Length or chunked body), so a
    /// server that keeps the connection open does not hold the fetch until its deadline.
    static func isComplete(_ raw: Data) -> Bool {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self).lowercased()
        let body = raw.distance(from: end.upperBound, to: raw.endIndex)
        if head.contains("transfer-encoding: chunked") { return raw.suffix(5) == Data("0\r\n\r\n".utf8) }
        guard let line = head.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
              let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) else { return false }
        return body >= length
    }

    static func dechunk(_ data: Data, maximumBytes: Int) throws -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { throw HTTPError(reason: "chunk") }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw HTTPError(reason: "chunk size")
            }
            index = lineEnd.upperBound
            if size == 0 { return output }
            guard output.count + size <= maximumBytes else { throw HTTPError(reason: "too large") }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { throw HTTPError(reason: "chunk") }
            let chunkEnd = data.index(index, offsetBy: size)
            output.append(data[index..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
        throw HTTPError(reason: "chunk")
    }

    /// One connection's request and its whole answer, on the connection's own queue.
    nonisolated final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let limit: Int
        private let queue = DispatchQueue(label: "com.cmuxterm.next.remote-image")
        // Queue-confined.
        private var received = Data()
        private var continuation: CheckedContinuation<Data, any Error>?

        init(connection: NWConnection, limit: Int) {
            self.connection = connection
            self.limit = limit
        }

        func run(_ request: Data) async throws -> Data {
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
                if let content { received.append(content) }
                if received.count > limit { return finish(.failure(HTTPError(reason: "too large"))) }
                if let error { return finish(.failure(error)) }
                if complete || PinnedTLSTransport.isComplete(received) { return finish(.success(received)) }
                receive()
            }
        }

        private func finish(_ result: Result<Data, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
