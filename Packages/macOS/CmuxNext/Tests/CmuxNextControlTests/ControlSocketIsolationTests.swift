@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// architecture.md 5a: a slow or stuck client only affects itself.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlSocketIsolationTests {
    func makeServer(outboxBytes: Int = 8 << 20) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor())
        router.snapshots.publish { $0 = .sample() }
        let server = ControlSocketServer(
            configuration: .init(path: temporarySocketPath(), accessMode: .allowAll, maxOutboxBytesPerConnection: outboxBytes),
            router: router
        )
        try server.start()
        return server
    }

    @Test func pipelinedRequestsBeyondTheInboundCapAreAllAnsweredInOrder() throws {
        let server = try makeServer()
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        let count = 500
        var batch = ""
        for index in 0..<count {
            batch += JSONValue.object(["id": JSONValue(index), "method": "system.ping"]).compactText + "\n"
        }
        let bytes = Array(batch.utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes[sent...].withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }
            guard written > 0 else { break }
            sent += written
        }
        for index in 0..<count {
            let response = try JSONValue.parse(Data(client.readLine().utf8))
            #expect(response["id"] == JSONValue(index))
        }
    }

    @Test func aClientThatStopsReadingIsDroppedWithoutSlowingOthers() throws {
        let server = try makeServer(outboxBytes: 256 << 10)
        defer { server.stop() }
        // The stuck client floods large responses and never reads them.
        let stuck = try LineClient(path: server.configuration.path)
        _ = fcntl(stuck.descriptor, F_SETFL, fcntl(stuck.descriptor, F_GETFL) | O_NONBLOCK)
        let request = Array((JSONValue.object(["id": 1, "method": "action.list"]).compactText + "\n").utf8)
        var flooded = 0
        let floodEnd = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < floodEnd {
            let written = request.withUnsafeBytes { write(stuck.descriptor, $0.baseAddress, $0.count) }
            if written <= 0 {
                if errno == EAGAIN { continue }
                break  // EPIPE/ECONNRESET: the server dropped us.
            }
            flooded += 1
        }
        #expect(flooded > 0)
        // Another client is still served promptly.
        let healthy = try LineClient(path: server.configuration.path)
        for _ in 0..<20 {
            let started = ContinuousClock.now
            let response = try healthy.call("system.identify")
            #expect(response["ok"] == true)
            #expect(ContinuousClock.now - started < .milliseconds(200))
        }
        // The stuck client was disconnected once its outbox passed the cap.
        var waited = 0
        while server.connectionCount > 1, waited < 200 {
            usleep(10_000)
            waited += 1
        }
        #expect(server.connectionCount == 1)
    }
}
