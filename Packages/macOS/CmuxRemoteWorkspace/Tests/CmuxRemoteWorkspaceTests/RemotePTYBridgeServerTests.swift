import CmuxRemoteDaemon
import Foundation
import Network
import Testing
@testable import CmuxRemoteWorkspace

/// Test double recording RPC traffic; thread-safe via a lock because the
/// bridge calls it from its rpc queue while the test thread inspects it.
final class RecordingPTYBridgeRPCClient: RemotePTYBridgeRPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Data] = []
    private var _onEvent: ((RemotePTYBridgeEvent) -> Void)?
    private var _eventQueue: DispatchQueue?
    var attachError: (any Error)?

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _writes
    }

    func emit(_ event: RemotePTYBridgeEvent) {
        lock.lock()
        let onEvent = _onEvent
        let queue = _eventQueue
        lock.unlock()
        queue?.async { onEvent?(event) }
    }

    func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (RemotePTYBridgeEvent) -> Void
    ) throws -> RemotePTYBridgeAttachment {
        if let attachError { throw attachError }
        lock.lock()
        _onEvent = onEvent
        _eventQueue = queue
        lock.unlock()
        return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "attach-token-1")
    }

    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        completion: @escaping ((any Error)?) -> Void
    ) {
        lock.lock()
        _writes.append(data)
        lock.unlock()
        completion(nil)
    }

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
}


private final class DeferredRecordingPTYBridgeRPCClient: RemotePTYBridgeRPCClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Data] = []
    private var completions: [((any Error)?) -> Void] = []
    private var _onEvent: ((RemotePTYBridgeEvent) -> Void)?
    private var _eventQueue: DispatchQueue?

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _writes
    }

    func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (RemotePTYBridgeEvent) -> Void
    ) throws -> RemotePTYBridgeAttachment {
        lock.lock()
        _onEvent = onEvent
        _eventQueue = queue
        lock.unlock()
        return RemotePTYBridgeAttachment(attachmentID: attachmentID, token: "deferred-token")
    }

    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        completion: @escaping ((any Error)?) -> Void
    ) {
        lock.lock()
        _writes.append(data)
        completions.append(completion)
        lock.unlock()
    }

    func completePendingWrites() {
        let pending: [((any Error)?) -> Void]
        lock.lock()
        pending = completions
        completions.removeAll(keepingCapacity: true)
        lock.unlock()
        for completion in pending {
            completion(nil)
        }
    }

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
}

struct TestPTYBridgeStrings: RemotePTYBridgeStrings {
    var missingPersistentPTYCapability: String { "test-missing-capability" }
    var sessionEnded: String { "test-session-ended" }
    var inputBackedUp: String { "test-input-backed-up" }
    var daemonTimeout: String { "test-daemon-timeout" }
    func allocationDiagnostic(_ message: String) -> String { "diag:\(message)" }
    var attachFailed: String { "test-attach-failed" }
}

/// Loopback TCP client helper for talking to a bridge endpoint.
private final class BridgeTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bridge-test-client")
    private let lock = NSLock()
    private var received = Data()
    private var closed = false

    init(endpoint: RemotePTYBridgeServer.Endpoint) {
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: UInt16(endpoint.port))!,
            using: .tcp
        )
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self.received.append(data) }
            if isComplete || error != nil { self.closed = true }
            let done = self.closed
            self.lock.unlock()
            if !done { self.receiveLoop() }
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Polls until `predicate` over the received bytes holds or the deadline
    /// passes (generous upper bound only; the happy path returns quickly).
    func waitForReceived(timeout: TimeInterval = 5.0, _ predicate: (Data, Bool) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let snapshot = received
            let isClosed = closed
            lock.unlock()
            if predicate(snapshot, isClosed) { return true }
            usleep(20_000)
        }
        return false
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func cancel() {
        connection.cancel()
    }
}

@Suite("RemotePTYBridgeServer")
struct RemotePTYBridgeServerTests {
    private func makeServer(
        client: any RemotePTYBridgeRPCClient,
        onStop: @escaping () -> Void = {}
    ) -> RemotePTYBridgeServer {
        RemotePTYBridgeServer(
            rpcClient: client,
            sessionID: "session-1",
            attachmentID: "attachment-1",
            command: nil,
            requireExisting: false,
            strings: TestPTYBridgeStrings(),
            onStop: onStop
        )
    }

    private func patternedInput(byteCount: Int) -> Data {
        var data = Data()
        data.reserveCapacity(byteCount)
        for index in 0..<byteCount {
            data.append(UInt8(index % 251))
        }
        return data
    }

    private func waitUntil(timeout: TimeInterval = 5.0, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            usleep(20_000)
        }
        return predicate()
    }

    // Regression test for https://github.com/manaflow-ai/cmux/issues/7708:
    // input-window overflow must never close the bridge session or drop
    // accepted bytes; it must backpressure and eventually deliver every
    // byte to writePTY in order.
    @Test("legacy input overflow pauses instead of closing and preserves order")
    func legacyInputOverflowPausesAndPreservesOrder() throws {
        let rpc = DeferredRecordingPTYBridgeRPCClient()
        let server = makeServer(client: rpc)
        defer { server.stop() }
        let endpoint = try server.start()

        let client = BridgeTestClient(endpoint: endpoint)
        defer { client.cancel() }
        client.send(Data("{\"token\":\"\(endpoint.token)\",\"cols\":120,\"rows\":40}\n".utf8))
        #expect(client.waitForReceived { data, _ in
            String(decoding: data, as: UTF8.self).contains("\"attachment_token\":\"deferred-token\"")
        })

        let input = patternedInput(byteCount: 5 * 1024 * 1024)
        client.send(input)

        // Phase 1: with no write completions the input window must fill and
        // the session must backpressure (pause socket reads) — never close.
        let windowFillTarget = 3 * 1024 * 1024
        #expect(waitUntil(timeout: 10.0) {
            rpc.writes.reduce(0) { $0 + $1.count } >= windowFillTarget || client.isClosed
        })
        #expect(!client.isClosed)

        // Phase 2: draining completions must deliver every accepted byte,
        // in order, with the connection still open.
        let drainDeadline = Date().addingTimeInterval(15.0)
        while rpc.writes.reduce(0, { $0 + $1.count }) < input.count,
              Date() < drainDeadline {
            rpc.completePendingWrites()
            usleep(20_000)
        }
        rpc.completePendingWrites()
        // Compare via a Bool: on mismatch Swift Testing would otherwise try
        // to render a byte-level diff of two multi-megabyte Data values.
        let delivered = rpc.writes.reduce(Data(), +)
        #expect(delivered.count == input.count)
        let deliveredMatchesInput = delivered == input
        #expect(deliveredMatchesInput)
        #expect(!client.isClosed)
    }

    @Test("start binds a loopback endpoint with a fresh token")
    func startBindsLoopbackEndpoint() throws {
        let server = makeServer(client: RecordingPTYBridgeRPCClient())
        defer { server.stop() }
        let endpoint = try server.start()
        #expect(endpoint.host == "127.0.0.1")
        #expect(endpoint.port > 0)
        #expect(!endpoint.token.isEmpty)
        #expect(endpoint.sessionID == "session-1")
        #expect(endpoint.attachmentID == "attachment-1")
    }

    @Test("a valid handshake attaches and the bridge pumps both directions")
    func handshakeAttachesAndPumps() throws {
        let rpc = RecordingPTYBridgeRPCClient()
        let server = makeServer(client: rpc)
        defer { server.stop() }
        let endpoint = try server.start()

        let client = BridgeTestClient(endpoint: endpoint)
        defer { client.cancel() }
        client.send(Data("{\"token\":\"\(endpoint.token)\",\"cols\":120,\"rows\":40}\n".utf8))

        // The bridge answers with the newline-terminated ready status line
        // carrying the daemon attachment token (wire-pinned shape).
        #expect(client.waitForReceived { data, _ in
            String(decoding: data, as: UTF8.self).contains("\"attachment_token\":\"attach-token-1\"")
        })

        // Client input is forwarded to pty.write.
        client.send(Data("ls -la\n".utf8))
        let deadline = Date().addingTimeInterval(5.0)
        while rpc.writes.isEmpty, Date() < deadline {
            usleep(20_000)
        }
        #expect(rpc.writes.reduce(Data(), +) == Data("ls -la\n".utf8))

        // PTY output events flow back to the socket.
        rpc.emit(.data(Data("OUTPUT".utf8)))
        #expect(client.waitForReceived { data, _ in
            String(decoding: data, as: UTF8.self).contains("OUTPUT")
        })
    }

    @Test("a wrong handshake token closes the connection without attaching")
    func wrongTokenCloses() throws {
        let rpc = RecordingPTYBridgeRPCClient()
        let server = makeServer(client: rpc)
        defer { server.stop() }
        let endpoint = try server.start()

        let client = BridgeTestClient(endpoint: endpoint)
        defer { client.cancel() }
        client.send(Data("{\"token\":\"wrong\"}\n".utf8))

        #expect(client.waitForReceived { data, closed in
            closed && data.isEmpty
        })
    }

    @Test("a failed attach reports the mapped error line before closing")
    func failedAttachReportsErrorLine() throws {
        let rpc = RecordingPTYBridgeRPCClient()
        rpc.attachError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "request timed out",
        ])
        let server = makeServer(client: rpc)
        defer { server.stop() }
        let endpoint = try server.start()

        let client = BridgeTestClient(endpoint: endpoint)
        defer { client.cancel() }
        client.send(Data("{\"token\":\"\(endpoint.token)\"}\n".utf8))

        #expect(client.waitForReceived { data, _ in
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("\"type\":\"error\"") && text.contains("test-daemon-timeout")
        })
    }

    @Test("stop is idempotent and fires onStop exactly once")
    func stopFiresOnStopOnce() throws {
        let counter = NSLock()
        nonisolated(unsafe) var stops = 0
        let server = makeServer(client: RecordingPTYBridgeRPCClient()) {
            counter.lock()
            stops += 1
            counter.unlock()
        }
        _ = try server.start()
        server.stop()
        server.stop()

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            counter.lock()
            let current = stops
            counter.unlock()
            if current >= 1 { break }
            usleep(20_000)
        }
        counter.lock()
        let final = stops
        counter.unlock()
        #expect(final == 1)
    }
}
