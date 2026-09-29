import Darwin
import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Non-empty lines of a `.jsonl` fixture.
    static func lines(_ name: String) throws -> [Data] {
        try data(name).split(separator: 0x0A).filter { !$0.isEmpty }.map { Data($0) }
    }

    /// `data` of a captured `{id, ok, data}` response line.
    static func response<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try WireCoding.decodeResponse(T.self, from: data(name))
    }

    static func eventName(_ line: Data) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: line))?["event"]?.stringValue
    }
}

/// Minimal scripted Unix-socket server for transport tests. `handler` gets
/// each request object and returns raw lines to write back.
final class FakeDaemonServer: Sendable {
    let path: String
    private let listenFD: Int32
    private let clientFD = FDBox()

    init(handler: @escaping @Sendable (_ request: [String: JSONValue]) -> [String]) throws {
        let path = "/tmp/cnd-\(UUID().uuidString.prefix(8)).sock"
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw DaemonError.connectFailed(path: path, errno: errno) }
        listenFD = fd
        let box = clientFD
        let thread = Thread {
            // One reader thread per client; `push` and `disconnectClient`
            // act on the first (the control connection).
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                box.fd.withLock { if $0 < 0 { $0 = client } }
                Thread { Self.serve(client, handler: handler) }.start()
            }
        }
        thread.start()
    }

    private static func serve(_ client: Int32, handler: @Sendable ([String: JSONValue]) -> [String]) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard case .object(let request)? = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
                for reply in handler(request) {
                    let bytes = Array((reply + "\n").utf8)
                    _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                }
            }
        }
    }

    /// Pushes an unsolicited line (an event) to the connected client.
    func push(_ line: String) {
        let fd = clientFD.fd.withLock { $0 }
        guard fd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Drops the client connection (simulates a daemon crash).
    func disconnectClient() {
        clientFD.fd.withLock { fd in
            if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        }
    }

    func stop() {
        disconnectClient()
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }
}

extension JSONValue {
    var intValue: Int? { doubleValue.map { Int($0) } }
}

/// Clock whose sleeps return at once (reconnect backoff in tests).
struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

final class FDBox: Sendable {
    let fd = Mutex<Int32>(-1)
}
