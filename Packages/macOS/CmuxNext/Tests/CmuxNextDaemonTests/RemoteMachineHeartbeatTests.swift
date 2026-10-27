import CmuxNextCompat
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// p09-observability-116: a daemon on another machine behind a forwarded socket (an SSH bridge machine, a Cloud
/// machine) has no bridge child on its endpoint, and its connection still runs the heartbeat, so its trace
/// clock offset is measured.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteMachineHeartbeatTests {
    @Test func aRemoteMachineWithNoBridgeChildGetsAClockOffset() async throws {
        let daemon = try ClockDaemon()
        defer { daemon.stop() }
        let endpoint = DaemonEndpoint(socketPath: daemon.path)
        #expect(endpoint.bridge == nil, "the SSH and Cloud routes forward a socket; no child runs")
        var configuration = DaemonConnection.Configuration(requiredCapabilities: [], terminalEnvironment: nil)
        configuration.remoteMachine = true
        // Each ask waits up to its interval; no miss may close the connection before the second ask.
        configuration.heartbeat = .seconds(1)
        configuration.heartbeatMisses = 100
        #expect(configuration.heartbeats(endpoint))
        let connection = DaemonConnection(endpoint: endpoint, configuration: configuration)
        _ = try await connection.start()

        // The heartbeat arms its next ask only after it kept the last answer, so the second ask proves the first counted.
        var asks = daemon.clockAsks.makeAsyncIterator()
        _ = await asks.next()
        _ = await asks.next()
        let offset = try #require(connection.traceClockOffset())
        #expect(offset.remoteDomain == "monotonic")
        await connection.close()
    }

    @Test func onlyTheFlagsAndABridgeChildRunTheHeartbeat() {
        let socket = DaemonEndpoint(socketPath: "/tmp/cmux-remote-heartbeat.sock")
        var configuration = DaemonConnection.Configuration(requiredCapabilities: [], terminalEnvironment: nil)
        #expect(!configuration.heartbeats(socket), "a page relay or a short read adds no idle wakeups")
        configuration.remoteMachine = true
        #expect(configuration.heartbeats(socket))
        configuration.remoteMachine = false
        configuration.localHeartbeat = true
        #expect(configuration.heartbeats(socket))
    }
}

/// A Unix socket served by this test process: `identify` answers the handshake, and with `trace_clock` it adds a
/// trace clock reading and yields on ``clockAsks``; every other request gets `ok:true`.
private final class ClockDaemon: Sendable {
    let path = "/tmp/cnd-clock-\(UUID().uuidString.prefix(8).lowercased()).sock"
    let clockAsks: AsyncStream<Void>
    private let asked: AsyncStream<Void>.Continuation
    private let listener: Int32

    init() throws {
        (clockAsks, asked) = AsyncStream.makeStream(of: Void.self)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        let asked = asked
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let serving = Thread { Self.serve(client, asked: asked) }
                serving.qualityOfService = .utility
                serving.start()
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        asked.finish()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private static func serve(_ client: Int32, asked: AsyncStream<Void>.Continuation) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var clock: UInt64 = 5_000_000_000
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = request["id"] as? Int, let command = request["cmd"] as? String else { continue }
                var data: [String: Any] = [:]
                let clocked = command == IdentifyRequest.command && request["trace_clock"] as? Bool == true
                if command == IdentifyRequest.command {
                    data = ["app": "cmux-tui", "protocol": 12, "generation": "gen-clock",
                            "capabilities": [DaemonCapability.traceFetch.rawValue]]
                }
                if clocked {
                    clock += 1_000_000
                    data["trace_clock_ns"] = clock
                    data["trace_clock_domain"] = "monotonic"
                }
                guard send(["id": id, "ok": true, "data": data], to: client) else { return }
                if clocked { asked.yield() }
            }
        }
    }

    /// Writes `object` and its newline whole.
    private static func send(_ object: [String: Any], to client: Int32) -> Bool {
        guard var bytes = try? JSONSerialization.data(withJSONObject: object) else { return false }
        bytes.append(0x0A)
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base + offset, raw.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
