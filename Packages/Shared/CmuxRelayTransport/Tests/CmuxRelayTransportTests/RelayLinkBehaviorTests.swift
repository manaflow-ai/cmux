// Behavior tests for the host link and client transport against a scripted
// fake relay connection: session demux, close semantics, and the
// host-absent connect failure.

import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxRelayTransport

/// Scripted RelayConnecting: the test injects server events and records
/// everything the code under test sends.
actor FakeRelayConnection: RelayConnecting {
    let welcome: RelayWelcome
    private var continuation: AsyncStream<RelayConnectionEvent>.Continuation?
    private let stream: AsyncStream<RelayConnectionEvent>
    private(set) var sentData: [RelayDataFrame] = []
    private(set) var sentControl: [String] = []
    private(set) var closed = false

    init(welcome: RelayWelcome) {
        self.welcome = welcome
        var storedContinuation: AsyncStream<RelayConnectionEvent>.Continuation?
        stream = AsyncStream { storedContinuation = $0 }
        continuation = storedContinuation
    }

    func connect() async throws -> RelayWelcome { welcome }

    func events() async -> AsyncStream<RelayConnectionEvent> { stream }

    func sendData(sessionID: UInt32, payload: Data) async throws {
        sentData.append(RelayDataFrame(sessionID: sessionID, payload: payload))
    }

    func sendControl(_ json: Data) async throws {
        sentControl.append(String(decoding: json, as: UTF8.self))
    }

    func close() async {
        closed = true
        continuation?.finish()
        continuation = nil
    }

    func inject(_ event: RelayConnectionEvent) {
        continuation?.yield(event)
    }

    func finishEvents() {
        continuation?.finish()
        continuation = nil
    }
}

private func farDeadline() -> Double {
    (Date().timeIntervalSince1970 + 3600) * 1000
}

@Suite struct RelayClientByteTransportTests {
    private func makeTransport(
        welcome: RelayWelcome
    ) -> (RelayClientByteTransport, FakeRelayConnection) {
        let fake = FakeRelayConnection(welcome: welcome)
        let transport = RelayClientByteTransport(
            hostDeviceID: "host-1",
            deviceID: { "phone-1" },
            accessToken: { "stack-token-1" },
            makeConnection: { _, _ in fake }
        )
        return (transport, fake)
    }

    @Test func refusesToConnectWithoutHost() async {
        let (transport, _) = makeTransport(
            welcome: RelayWelcome(v: 1, role: .client, sessionId: 5, deadline: farDeadline(), hostPresent: false)
        )
        await #expect(throws: RelayTransportError.hostNotConnected) {
            try await transport.connect()
        }
    }

    @Test func deliversRPCChannelBytesAndSendsStampedFrames() async throws {
        let (transport, fake) = makeTransport(
            welcome: RelayWelcome(v: 1, role: .client, sessionId: 5, deadline: farDeadline(), hostPresent: true)
        )
        try await transport.connect()

        await fake.inject(.data(RelayDataFrame(
            sessionID: 5,
            payload: RelayFrameCodec.channelPayload(channel: RelayProtocol.channelRPC, data: Data([1, 2]))
        )))
        let received = try await transport.receive()
        #expect(received == Data([1, 2]))

        try await transport.send(Data([9]))
        let sent = await fake.sentData
        // Frame 0 is the admission written by connect(); frame 1 is ours.
        #expect(sent.count == 2)
        #expect(sent.last?.sessionID == RelayProtocol.hostSessionID)
        #expect(RelayFrameCodec.splitChannel(sent.last?.payload ?? Data())?.data == Data([9]))
        await transport.close()
    }

    /// The FIRST bytes a client session puts on the wire are the end-to-end
    /// admission request carrying the account token, so the host can bind the
    /// session before any other request exists.
    @Test func connectSendsAdmissionBeforeAnythingElse() async throws {
        let (transport, fake) = makeTransport(
            welcome: RelayWelcome(v: 2, role: .client, sessionId: 5, deadline: farDeadline(), hostPresent: true)
        )
        try await transport.connect()

        let sent = await fake.sentData
        #expect(sent.count == 1)
        let first = try #require(sent.first)
        #expect(first.sessionID == RelayProtocol.hostSessionID)
        let split = try #require(RelayFrameCodec.splitChannel(first.payload))
        #expect(split.channel == RelayProtocol.channelRPC)
        var buffer = split.data
        let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        let frame = try #require(frames.first)
        let parsed = try JSONSerialization.jsonObject(with: frame)
        let envelope = try #require(parsed as? [String: Any])
        #expect(envelope["method"] as? String == RelayAdmission.method)
        #expect(envelope["id"] as? String == RelayAdmission.requestID)
        let auth = try #require(envelope["auth"] as? [String: Any])
        #expect(auth["stack_access_token"] as? String == "stack-token-1")
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(params["device_id"] as? String == "phone-1")
        await transport.close()
    }

    @Test func hostDepartureEndsTheStream() async throws {
        let (transport, fake) = makeTransport(
            welcome: RelayWelcome(v: 1, role: .client, sessionId: 5, deadline: farDeadline(), hostPresent: true)
        )
        try await transport.connect()
        await fake.inject(.control(.peerLeft(RelayPeerLeft(sessionId: 0, reason: "closed"))))
        let received = try await transport.receive()
        #expect(received == nil)
        await transport.close()
    }
}

@Suite struct RelayHostLinkTests {
    @Test func demuxesSessionsAndClosesThem() async throws {
        let fake = FakeRelayConnection(
            welcome: RelayWelcome(v: 1, role: .host, sessionId: 0, deadline: farDeadline(), hostPresent: true)
        )
        let seen = SessionRecorder()
        let link = RelayHostLink(
            hostDeviceID: "host-1",
            accessToken: { "stack-token-mac" },
            makeConnection: { _, _ in fake },
            onClientSession: { session in
                await seen.record(session)
                // Echo the first frame, then return: a host-side owner
                // finishing its RPC loop.
                if let first = (try? await session.transport.receive()) ?? nil {
                    try? await session.transport.send(first)
                }
            }
        )
        let runTask = Task { await link.run() }

        await fake.inject(.control(.peerJoined(RelayPeerJoined(sessionId: 3, deviceId: "phone-a"))))
        await fake.inject(.data(RelayDataFrame(
            sessionID: 3,
            payload: RelayFrameCodec.channelPayload(channel: RelayProtocol.channelRPC, data: Data([42]))
        )))

        // The handler echoes the byte back, stamped with session 3.
        try await waitUntil("echo frame sent") {
            await fake.sentData.contains { $0.sessionID == 3 }
        }
        let sessions = await seen.sessions
        #expect(sessions == [["phone-a", "3"]])

        // The handler returned, so the link tells the relay to close that
        // client's socket.
        try await waitUntil("close_session sent") {
            await fake.sentControl.contains { $0.contains("close_session") }
        }

        await link.stop()
        await fake.finishEvents()
        runTask.cancel()
    }

    @Test func peerLeftEndsTheSessionStreamWithoutCloseSession() async throws {
        let fake = FakeRelayConnection(
            welcome: RelayWelcome(v: 1, role: .host, sessionId: 0, deadline: farDeadline(), hostPresent: true)
        )
        let ended = SessionRecorder()
        let link = RelayHostLink(
            hostDeviceID: "host-1",
            accessToken: { "stack-token-mac" },
            makeConnection: { _, _ in fake },
            onClientSession: { session in
                // Consume until EOF (the peer_left), then record.
                while ((try? await session.transport.receive()) ?? nil) != nil {}
                await ended.record(session)
            }
        )
        let runTask = Task { await link.run() }

        // Events are handled in order by the link's pump, so the join lands
        // before the leave.
        await fake.inject(.control(.peerJoined(RelayPeerJoined(sessionId: 8, deviceId: "phone-b"))))
        await fake.inject(.control(.peerLeft(RelayPeerLeft(sessionId: 8, reason: "closed"))))
        try await waitUntil("handler unwound via EOF") {
            await ended.sessions == [["phone-b", "8"]]
        }
        // The peer already left; no close_session goes to the relay.
        let control = await fake.sentControl
        #expect(!control.contains { $0.contains("close_session") })

        await link.stop()
        await fake.finishEvents()
        runTask.cancel()
    }
}

actor SessionRecorder {
    private(set) var sessions: [[String]] = []

    func record(_ session: RelayClientSession) {
        sessions.append([session.clientDeviceID, String(session.sessionID)])
    }
}

func waitUntil(
    _ label: String,
    timeout: Duration = .seconds(5),
    condition: @Sendable () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for \(label)")
}
