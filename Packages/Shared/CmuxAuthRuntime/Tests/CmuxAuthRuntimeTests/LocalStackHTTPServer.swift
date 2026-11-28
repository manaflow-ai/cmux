import Foundation
import Network

/// A real HTTP/1.1 server on 127.0.0.1 that stands in for the sign-in
/// service, so tests drive the production Stack client over a socket.
///
/// Each `METHOD /path` has a queue of scripted responses; the last one
/// repeats. Unscripted paths answer `200 {"items":[]}`.
final class LocalStackHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Response {
            Response(
                status: status,
                headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
                body: Data(body.utf8)
            )
        }

        static func html(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Response {
            Response(
                status: status,
                headers: headers.merging(["Content-Type": "text/html; charset=UTF-8"]) { current, _ in current },
                body: Data(body.utf8)
            )
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalStackHTTPServer")
    private let lock = NSLock()
    private var scripts: [String: [Response]] = [:]
    private var counts: [String: Int] = [:]
    private var statusCounts: [String: Int] = [:]
    private var boundPort: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns once the port is bound.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard resumed.setOnce() else { return }
                    if let self { self.withLock { self.boundPort = self.listener.port?.rawValue ?? 0 } }
                    continuation.resume()
                case let .failed(error):
                    guard resumed.setOnce() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: String {
        "http://127.0.0.1:\(withLock { boundPort })"
    }

    func script(_ method: String, _ path: String, _ responses: [Response]) {
        withLock { scripts["\(method) \(path)"] = responses }
    }

    func requestCount(_ method: String, _ path: String) -> Int {
        withLock { counts["\(method) \(path)"] ?? 0 }
    }

    /// How many answers to `METHOD /path` carried `status`.
    func responseCount(_ method: String, _ path: String, status: Int) -> Int {
        withLock { statusCounts["\(method) \(path) \(status)"] ?? 0 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func nextResponse(method: String, path: String) -> Response {
        withLock {
            let key = "\(method) \(path)"
            counts[key, default: 0] += 1
            guard var queued = scripts[key], let first = queued.first else {
                statusCounts["\(key) 200", default: 0] += 1
                return .json(200, #"{"items":[]}"#)
            }
            if queued.count > 1 {
                queued.removeFirst()
                scripts[key] = queued
            }
            statusCounts["\(key) \(first.status)", default: 0] += 1
            return first
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(to: request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func respond(to request: (method: String, path: String), on connection: NWConnection) {
        let response = nextResponse(method: request.method, path: request.path)
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Returns the request line once headers and the declared body arrived.
    private static func parse(_ buffer: Data) -> (method: String, path: String)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex) >= contentLength else {
            return nil
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return (String(requestLine[0]), path)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        default: return "Status"
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isSet { return false }
        isSet = true
        return true
    }
}

/// A syntactically valid unsigned JWT carrying only `iat` and `exp`, the
/// claims the client reads to decide when to refresh.
func testAccessJWT(issuedSecondsAgo: Int, expiresInSeconds: Int, now: Date = Date()) -> String {
    let nowSeconds = Int(now.timeIntervalSince1970)
    func encode(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = encode(#"{"alg":"HS256","typ":"JWT"}"#)
    let claims = encode(#"{"sub":"user-1","iat":\#(nowSeconds - issuedSecondsAgo),"exp":\#(nowSeconds + expiresInSeconds)}"#)
    return "\(header).\(claims).c2lnbmF0dXJlLW5vdC1jaGVja2Vk"
}

/// A fresh, empty directory for one test's file token store.
func makeBoundaryTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-auth-boundary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
