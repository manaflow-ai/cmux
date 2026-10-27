import Foundation
#if canImport(Network)
import Network
#endif
import Testing
@testable import CmuxNextChromiumRuntime

/// The app's downloader against a loopback HTTP server: a whole download, a
/// resume with `Range`, a server that ignores `Range`, and an error status.
struct URLSessionChromiumRuntimeDownloaderTests {
    let folder: TemporaryFolder
    let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    init() throws { folder = try TemporaryFolder() }

    @Test func downloadsTheWholeBody() async throws {
        let server = try await LoopbackServer.start(body: body)
        defer { server.stop() }
        let file = folder.url.appending(path: "pack.partial")
        try await URLSessionChromiumRuntimeDownloader().download(server.url, to: file, expectedSize: Int64(body.count)) { _ in }
        #expect(try Data(contentsOf: file) == body)
        #expect(server.ranges() == [nil])
    }

    @Test func resumesAfterThePartialFile() async throws {
        let server = try await LoopbackServer.start(body: body)
        defer { server.stop() }
        let file = folder.url.appending(path: "pack.partial")
        try body.prefix(100_000).write(to: file)
        try await URLSessionChromiumRuntimeDownloader().download(server.url, to: file, expectedSize: Int64(body.count)) { _ in }
        #expect(try Data(contentsOf: file) == body)
        #expect(server.ranges() == ["bytes=100000-"])
    }

    @Test func startsAgainWhenTheServerIgnoresRange() async throws {
        let server = try await LoopbackServer.start(body: body, honorsRange: false)
        defer { server.stop() }
        let file = folder.url.appending(path: "pack.partial")
        try Data(repeating: 0xEE, count: 50_000).write(to: file)
        try await URLSessionChromiumRuntimeDownloader().download(server.url, to: file, expectedSize: Int64(body.count)) { _ in }
        #expect(try Data(contentsOf: file) == body)
    }

    @Test func anErrorStatusFails() async throws {
        let server = try await LoopbackServer.start(body: body, status: 404)
        defer { server.stop() }
        let file = folder.url.appending(path: "pack.partial")
        await #expect(throws: ChromiumRuntimeInstallError.http(404)) {
            try await URLSessionChromiumRuntimeDownloader().download(server.url, to: file, expectedSize: Int64(body.count)) { _ in }
        }
    }
}

/// The loopback server's answer to one request, on every platform: an empty error reply when
/// `status` is not 200, the part after `Range: bytes=N-` as a 206 when the server honors ranges,
/// else the whole body as a 200; `range` is the request's Range header.
struct LoopbackReply {
    let range: String?
    let bytes: Data

    init(request data: Data, body: Data, honorsRange: Bool, status: Int) {
        let request = String(decoding: data, as: UTF8.self)
        let range = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        var payload = body
        var head: String
        if status != 200 {
            payload = Data()
            head = "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\n"
        } else if honorsRange, let range, range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).dropLast()) {
            payload = body.subdata(in: start..<body.count)
            head = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\nContent-Length: \(payload.count)\r\n"
        } else {
            head = "HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        self.range = range
        bytes = Data(head.utf8) + payload
    }
}

/// The requests' Range headers, appended by the server's queue or thread and read by the test.
// Appended on the server's queue, read by the test: a lock is enough here.
final class LoopbackRangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [String?] = []
    func append(_ range: String?) { lock.withLock { ranges.append(range) } }
    func all() -> [String?] { lock.withLock { ranges } }
}

#if canImport(Network)
/// A one-file HTTP/1.1 server on 127.0.0.1 (Network framework), enough for
/// `Range: bytes=N-`. Records each request's Range header.
final class LoopbackServer: Sendable {
    let url: URL
    private let listener: NWListener
    private let log: LoopbackRangeLog

    private init(url: URL, listener: NWListener, log: LoopbackRangeLog) {
        self.url = url
        self.listener = listener
        self.log = log
    }

    func ranges() -> [String?] { log.all() }

    func stop() { listener.cancel() }

    static func start(body: Data, honorsRange: Bool = true, status: Int = 200) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let log = LoopbackRangeLog()
        let queue = DispatchQueue(label: "loopback-server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                let answer = LoopbackReply(request: data ?? Data(), body: body, honorsRange: honorsRange, status: status)
                log.append(answer.range)
                connection.send(content: answer.bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return LoopbackServer(url: URL(string: "http://127.0.0.1:\(port)/pack.tar.xz")!, listener: listener, log: log)
    }
}

// One-shot resume guard for the listener's state callbacks (lock carve-out:
// synchronous compare-and-set from non-async callbacks).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
#endif
