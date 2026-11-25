@testable import CmuxDeviceHub
import Foundation
import Testing

/// A scripted socket: hands out `frames`, then fails like a dropped connection.
final class FakeConnection: DeviceHubSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String]
    private var sentFrames: [String] = []
    private(set) var closed = false

    init(_ frames: [String]) { self.frames = frames }

    var sent: [String] { lock.withLock { sentFrames } }

    func receive() async throws -> String {
        if let next = lock.withLock({ frames.isEmpty ? nil : frames.removeFirst() }) { return next }
        throw URLError(.networkConnectionLost)
    }

    func send(_ text: String) async throws { lock.withLock { sentFrames.append(text) } }
    func close() { lock.withLock { closed = true } }
}

/// Connections in order; past the last one every connect fails.
final class FakeConnector: DeviceHubSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeConnection]
    private(set) var attempts = 0

    init(_ connections: [FakeConnection]) { queue = connections }

    func connect() async throws -> any DeviceHubSocketConnection {
        let next = lock.withLock { () -> FakeConnection? in
            attempts += 1
            return queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let next else { throw URLError(.cannotConnectToHost) }
        return next
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DeviceHubSocket.Event] = []
    func append(_ event: DeviceHubSocket.Event) { lock.withLock { events.append(event) } }
    var all: [DeviceHubSocket.Event] { lock.withLock { events } }
}

@Suite struct DeviceHubSocketTests {
    @Test func pushMessagesDecode() throws {
        #expect(DeviceHubPush(text: #"{"type":"devices.changed"}"#) == .devicesChanged)
        #expect(DeviceHubPush(text: #"{"type":"permissions.changed","hostId":"h1"}"#) == .permissionsChanged(hostID: "h1"))
        #expect(DeviceHubPush(text: #"{"type":"relays.changed"}"#) == .relaysChanged)
        #expect(DeviceHubPush(text: #"{"type":"session.request","session":{"id":"s1","viewerId":"v1","viewerName":"Phone","viewerKeyFingerprint":"AB12","scope":"full"}}"#)
            == .sessionRequest(SessionRequest(id: "s1", viewerId: "v1", viewerName: "Phone", viewerKeyFingerprint: "AB12", scope: .full)))
        let ticketText = #"{"type":"session.ticket","sessionId":"s1","ticket":"h.p.s","signalURL":"wss://hub.example/v1/sessions/s1/ws","ice":[{"urls":["turn:cf:3478"],"username":"u","credential":"c"}],"peer":{"id":"h1","name":"Studio","signingKey":"BASE64"},"role":"viewer","scope":"view"}"#
        let ticket = SessionTicket(sessionId: "s1", ticket: "h.p.s", signalURL: URL(string: "wss://hub.example/v1/sessions/s1/ws")!,
                                   ice: [DeviceHubICEServer(urls: ["turn:cf:3478"], username: "u", credential: "c")],
                                   peer: .init(id: "h1", name: "Studio", signingKey: "BASE64"), role: .viewer, scope: .view)
        #expect(DeviceHubPush(text: ticketText) == .sessionTicket(ticket))
        #expect(ticket.signalSocketURL.absoluteString == "wss://hub.example/v1/sessions/s1/ws?ticket=h.p.s")
        #expect(DeviceHubPush(text: #"{"type":"session.denied","sessionId":"s1"}"#) == .sessionDenied(sessionID: "s1"))
        #expect(DeviceHubPush(text: #"{"type":"session.revoked","sessionId":"s1","reason":"device_removed"}"#)
            == .sessionRevoked(sessionID: "s1", reason: "device_removed"))
        #expect(DeviceHubPush(text: #"{"type":"session.ended","sessionId":"s1","reason":"bye"}"#) == .sessionEnded(sessionID: "s1", reason: "bye"))
        #expect(DeviceHubPush(text: #"{"type":"pong"}"#) == .pong)
        #expect(DeviceHubPush(text: #"{"type":"later.thing"}"#) == .unknown("later.thing"))
        #expect(DeviceHubPush(text: "not json") == nil)
        #expect(DeviceHubPush(text: #"{"type":"session.denied"}"#) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func theSocketDeliversPushesAndReconnectsAfterADrop() async throws {
        let first = FakeConnection([#"{"type":"devices.changed"}"#])
        let second = FakeConnection([#"{"type":"relays.changed"}"#])
        let connector = FakeConnector([first, second])
        let socket = DeviceHubSocket(connector: connector, pingInterval: .seconds(3600),
                                     backoff: Backoff(initial: .milliseconds(1), maximum: .milliseconds(2), jitter: 0))
        let log = EventLog()
        let (done, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            await socket.run { event in
                log.append(event)
                if event == .push(.relaysChanged) { signal.yield() }
            }
        }
        for await _ in done { break }
        task.cancel()
        await task.value
        let events = log.all
        try #require(events.count >= 6)
        #expect(Array(events.prefix(3)) == [.state(.connecting), .state(.connected), .push(.devicesChanged)])
        guard case .state(.reconnecting) = events[3] else {
            Issue.record("expected a reconnect after the drop, got \(events[3])")
            return
        }
        #expect(Array(events[4 ..< 6]) == [.state(.connecting), .state(.connected)])
        #expect(events.contains(.push(.relaysChanged)))
        #expect(events.last == .state(.disconnected))
        #expect(first.closed)
    }

    @Test(.timeLimit(.minutes(1))) func aRemovedDevicesSocketStopsReconnecting() async {
        final class Removed: DeviceHubSocketConnection, @unchecked Sendable {
            func receive() async throws -> String { throw DeviceHubSocket.Closed(code: 4001) }
            func send(_ text: String) async throws {}
            func close() {}
        }
        struct Once: DeviceHubSocketConnector {
            let count = Locked(0)
            func connect() async throws -> any DeviceHubSocketConnection {
                count.set(count.value + 1)
                return Removed()
            }
        }
        let connector = Once()
        let log = EventLog()
        let socket = DeviceHubSocket(connector: connector, backoff: Backoff(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0))
        await socket.run { log.append($0) }
        #expect(log.all == [.state(.connecting), .state(.connected), .state(.removed)])
        #expect(connector.count.value == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aSignedOutDevicesSocketStopsReconnecting() async {
        final class SignedOut: DeviceHubSocketConnection, @unchecked Sendable {
            func receive() async throws -> String { throw DeviceHubSocket.Closed(code: 4003) }
            func send(_ text: String) async throws {}
            func close() {}
        }
        struct Once: DeviceHubSocketConnector {
            let count = Locked(0)
            func connect() async throws -> any DeviceHubSocketConnection {
                count.set(count.value + 1)
                return SignedOut()
            }
        }
        let connector = Once()
        let log = EventLog()
        // A reconnect would loop forever on this connector (each socket closes 4003 again), so
        // the run returning at all, after one connect and no `reconnecting`, is the check.
        let socket = DeviceHubSocket(connector: connector, backoff: Backoff(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0))
        let task = Task { await socket.run { log.append($0) } }
        let outcome = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                // Still reconnecting: end the socket's run so the group (and the test) can finish.
                task.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        task.cancel()
        await task.value
        #expect(outcome, "the socket kept reconnecting after a 4003 close")
        #expect(log.all == [.state(.connecting), .state(.connected), .state(.signedOut)])
        #expect(!log.all.contains { if case .state(.reconnecting) = $0 { true } else { false } })
        #expect(connector.count.value == 1)
    }

    @Test func onlyTheReplacedRemovedAndSignedOutCloseCodesAreTerminal() {
        #expect(DeviceHubSocket.terminalState(closeCode: 4000) == .replaced)
        #expect(DeviceHubSocket.terminalState(closeCode: 4001) == .removed)
        #expect(DeviceHubSocket.terminalState(closeCode: 4003) == .signedOut)
        #expect(DeviceHubSocket.terminalState(closeCode: 1006) == nil)
        #expect(DeviceHubSocket.terminalState(closeCode: 4002) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func theSocketPings() async throws {
        let connection = FakeConnection([])
        final class Blocking: DeviceHubSocketConnection, @unchecked Sendable {
            let inner: FakeConnection
            let pinged: AsyncStream<Void>.Continuation
            init(_ inner: FakeConnection, pinged: AsyncStream<Void>.Continuation) { self.inner = inner; self.pinged = pinged }
            func receive() async throws -> String {
                try await Task.sleep(for: .seconds(3600))
                throw CancellationError()
            }
            func send(_ text: String) async throws {
                try await inner.send(text)
                pinged.yield()
            }
            func close() { inner.close() }
        }
        let (pings, pinged) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        struct One: DeviceHubSocketConnector {
            let connection: Blocking
            func connect() async throws -> any DeviceHubSocketConnection { connection }
        }
        let socket = DeviceHubSocket(connector: One(connection: Blocking(connection, pinged: pinged)), pingInterval: .milliseconds(5))
        let task = Task { await socket.run { _ in } }
        for await _ in pings { break }
        task.cancel()
        await task.value
        #expect(connection.sent.first == #"{"type":"ping"}"#)
    }
}
