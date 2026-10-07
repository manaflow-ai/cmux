import CmuxControlPlane
import CmuxMobileWire
import Foundation
import Testing

/// E1: nothing the socket delivers, or the app sends, queues without bound
/// behind a consumer or a socket that stopped moving.
@Suite struct BackPressureTests {
    let host = "host_aaaaaaaaaaaaaaaaaaaa"
    var stream: String { "workspace:\(host)" }

    func makeClient(_ transport: any ControlPlaneTransport) -> ControlPlaneClient {
        let config = ControlPlaneConfiguration(
            url: URL(string: "wss://api.test/v1/wire/host/\(host)")!,
            client: HelloClient(install: "in_phone01", platform: "ios", appVersion: "1.0.0"),
            reconnect: ReconnectPolicy(delays: [.zero], sleep: { _ in })
        )
        return ControlPlaneClient(configuration: config, transport: transport, tokenProvider: { "tok-1" })
    }

    func event(_ seq: UInt64) -> MobileFrame {
        .event(EventFrame(stream: stream, seq: seq, tx: "tx_\(seq)", op: "workspace.upsert", params: .object([:]), actor: [:], origin: .user, at: Int64(seq)))
    }

    @Test func aSubscriberThatStopsReadingIsBoundedAndResyncsFromASnapshot() async throws {
        let transport = FakeControlPlaneTransport()
        let client = makeClient(transport)
        let updates = await client.subscribe(stream)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        _ = try await server.next(.subscribe)
        try server.send(.snapshot(SnapshotFrame(stream: stream, seq: 0, state: .object([:]), decided: [])))
        let total: UInt64 = 5000
        for seq in 1...total { try server.send(event(seq)) }
        // The subscriber read nothing: the client drops its backlog and asks
        // the owner for a fresh snapshot instead of queueing every event.
        guard case .snapshotRequest(let request)? = try await withTimeout(.seconds(5), { try await server.next(.snapshotRequest) }) else {
            Issue.record("no snapshot.request for a subscriber that stopped reading")
            await client.stop()
            return
        }
        #expect(request.stream == stream)
        try server.send(.snapshot(SnapshotFrame(stream: stream, seq: total, state: .object([:]), decided: [])))
        var before = 0
        for await update in updates {
            if case .snapshot(let snapshot) = update, snapshot.seq == total { break }
            before += 1
        }
        #expect(before <= 1025, "\(before) updates were queued before the resync snapshot")
        #expect(await client.cursor(of: stream) == total)
        await client.stop()
    }

    @Test func aStalledSocketRefusesSendsInsteadOfQueueingThem() async throws {
        let transport = StallingTransport()
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.inner.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        for await state in client.states { if case .connected = state { break } }
        transport.stall()
        var refused = 0
        for index in 0..<5000 {
            let signal = SignalFrame(kind: .ice, session: "sess_abc123", to: host, body: ["n": .string("\(index)")])
            do {
                try await client.sendSignal(signal)
            } catch {
                refused += 1
            }
        }
        #expect(refused > 0, "5000 frames queued behind a socket that accepts nothing")
        await client.stop()
    }

    @Test func aStatesConsumerThatNeverReadsKeepsOnlyRecentStates() async throws {
        let transport = FakeControlPlaneTransport()
        transport.refusals = 300
        let client = makeClient(transport)
        await client.start()
        var sockets = transport.sockets.makeAsyncIterator()
        let server = try #require(await sockets.next())
        _ = try await server.acceptHello()
        var seen = 0
        for await state in client.states {
            seen += 1
            if case .connected = state { break }
        }
        #expect(seen <= 32, "\(seen) states were buffered for a consumer that read nothing")
        await client.stop()
    }
}

/// A transport whose connections stop completing sends after `stall()`
/// (a socket whose peer stopped reading); `close` releases them.
final class StallingTransport: ControlPlaneTransport, @unchecked Sendable {
    let inner = FakeControlPlaneTransport()
    private let lock = NSLock()
    private var stalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func stall() { lock.withLock { stalled = true } }

    func connect(url: URL, protocols: [String]) async throws -> any ControlPlaneConnection {
        StallingConnection(inner: try await inner.connect(url: url, protocols: protocols), transport: self)
    }

    fileprivate func waitIfStalled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                guard stalled else { return false }
                waiters.append(continuation)
                return true
            }
            if !wait { continuation.resume() }
        }
    }

    fileprivate func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stalled = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

private struct StallingConnection: ControlPlaneConnection {
    let inner: any ControlPlaneConnection
    let transport: StallingTransport

    func send(_ text: String) async throws {
        await transport.waitIfStalled()
        try await inner.send(text)
    }

    func receive() async throws -> String { try await inner.receive() }

    func close(code: Int) async {
        transport.release()
        await inner.close(code: code)
    }
}

/// Runs `operation`, returning nil after `limit` of real time. The
/// operation runs unstructured, so a step stuck in a non-cancellable wait is
/// abandoned rather than awaited.
func withTimeout<T: Sendable>(_ limit: Duration = .seconds(5), _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    let gate = TimeoutGate<T>()
    let work = Task {
        do { await gate.resolve(.success(try await operation())) } catch { await gate.resolve(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        await gate.resolve(.success(nil))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await gate.value()
}

/// The first result wins.
actor TimeoutGate<T: Sendable> {
    private var result: Result<T?, any Error>?
    private var waiters: [CheckedContinuation<T?, any Error>] = []

    func resolve(_ outcome: Result<T?, any Error>) {
        guard result == nil else { return }
        result = outcome
        for waiter in waiters { waiter.resume(with: outcome) }
        waiters = []
    }

    func value() async throws -> T? {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}
