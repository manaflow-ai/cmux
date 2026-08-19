import CMUXMobileCore
import CmuxPeerTransportCore
import Foundation
import Testing

@testable import CmuxPeerTransport

/// End-to-end admission over live loopback QUIC: two real endpoints, single-
/// phase admission on the first control stream, RPC-style bytes over the
/// `CmxByteTransport` seam, application and server-event lanes both ways.
@Suite("PeerSession loopback", .serialized)
struct PeerSessionLoopbackTests {
    struct SessionFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// One JWS-shaped credential (the codec validates compact-JWS form; the
    /// admission controller's verifyGrant closure decides validity).
    static let goodCredential = "eyJh.eyJi.c2ln"
    static let badCredential = "eyJh.eyJi.YmFk"

    @Test(.timeLimit(.minutes(3)))
    func admissionAndLanesOverLoopback() async throws {
        var lastError: any Error = SessionFailure(reason: "never ran")
        for attempt in 1...2 {
            do {
                try await runLoopback()
                return
            } catch {
                lastError = error
                if attempt == 1 {
                    try await ContinuousClock().sleep(for: .milliseconds(500))
                }
            }
        }
        throw lastError
    }

    private func runLoopback() async throws {
        let host = PeerEndpointManager()
        let phone = PeerEndpointManager()
        do {
            try await exchange(host: host, phone: phone)
        } catch {
            await host.deactivate()
            await phone.deactivate()
            throw error
        }
        await host.deactivate()
        await phone.deactivate()
    }

    private func exchange(
        host: PeerEndpointManager,
        phone: PeerEndpointManager
    ) async throws {
        let hostGeneration = try await host.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        _ = try await phone.activate(
            secretKey: EndpointTestSupport.randomSecret(),
            relays: [],
            directOnly: true
        )
        guard let phoneEndpointID = await phone.endpointID else {
            throw SessionFailure(reason: "phone has no endpointID")
        }

        let admission = PeerAdmissionController(
            verifyGrant: { credential in
                guard credential == Self.goodCredential else {
                    throw SessionFailure(reason: "invalid credential")
                }
                return PeerVerifiedGrant(
                    grantID: "grant-loopback",
                    initiatorDeviceID: "phone-device",
                    acceptorDeviceID: "mac-device",
                    initiatorEndpointID: phoneEndpointID,
                    expiresAt: Date().addingTimeInterval(3600)
                )
            },
            brokerVerdict: { _ in .admitted }
        )

        // Host: accept connections, admit, then serve one terminal lane and
        // open one server-event lane.
        let hostSessionBox = TestSessionBox()
        let hostDone = TestCompletionBox()
        let acceptor = PeerHostSessionAcceptor()
        let listener = PeerInboundListener(
            manager: host,
            maxConcurrentUnauthenticated: 4
        ) { connection in
            guard let session = await acceptor.accept(
                connection: connection,
                admission: admission
            ) else {
                return
            }
            await hostSessionBox.store(session)
            await Self.runHostSide(session: session, done: hostDone)
        }
        try await listener.start(generation: hostGeneration)

        guard let hostEndpointID = await host.endpointID else {
            throw SessionFailure(reason: "host has no endpointID")
        }
        let hints = await EndpointTestSupport.loopbackHints(for: host)

        // Denied credential first: the connection must fail authorization.
        let dialer = PeerConnectionDialer(manager: phone)
        let deniedConnection = try await dialer.dial(
            endpointID: hostEndpointID,
            directHints: hints,
            timeout: .seconds(30)
        )
        do {
            _ = try await PeerClientSessionFactory().establish(
                connection: deniedConnection,
                credential: Self.badCredential
            )
            throw SessionFailure(reason: "bad credential was admitted")
        } catch let failure as PeerDialFailure {
            #expect(failure.classification == .authorizationDenied)
        }

        // Good credential: full session.
        let connection = try await dialer.dial(
            endpointID: hostEndpointID,
            directHints: hints,
            timeout: .seconds(30)
        )
        let session = try await PeerClientSessionFactory().establish(
            connection: connection,
            credential: Self.goodCredential
        )
        #expect(session.remoteEndpointID == hostEndpointID)

        // Control plane: RPC-style bytes over the CmxByteTransport seam.
        try await session.controlTransport.send(Data("rpc-request".utf8))
        guard let controlReply = try await session.controlTransport.receive() else {
            throw SessionFailure(reason: "control stream ended early")
        }
        #expect(String(decoding: controlReply, as: UTF8.self) == "rpc-response")

        // Terminal lane: client-opened, host receives resourceID + cursor.
        let terminal = try await session.openTerminalLane(
            resourceID: "surface-1",
            cursor: 42
        )
        try await terminal.write(Data("keystrokes".utf8))
        try await terminal.finish()
        let terminalEcho = try await terminal.readToEnd()
        #expect(String(decoding: terminalEcho, as: UTF8.self) == "echo:keystrokes")

        // Server-event lane: host-opened uni stream with cursor 7.
        var eventLanes = session.serverEventLanes().makeAsyncIterator()
        guard let eventLane = await eventLanes.next() else {
            throw SessionFailure(reason: "no server-event lane arrived")
        }
        #expect(eventLane.cursor == 7)
        var eventBytes = eventLane.initialBytes
        while let chunk = try await eventLane.stream.read() {
            eventBytes.append(chunk)
        }
        #expect(String(decoding: eventBytes, as: UTF8.self) == "event-payload")

        try await hostDone.awaitCompletion()

        // Client-initiated close resolves the host's exit await.
        guard let hostSession = await hostSessionBox.value else {
            throw SessionFailure(reason: "host session missing")
        }
        await session.close(reason: "test-done")
        let exit = await hostSession.awaitExit()
        if case .local = exit.reason {
            throw SessionFailure(reason: "host saw local close for a remote one")
        }
        await listener.stop()

        let clientClose = await session.awaitClose()
        #expect(clientClose == .local("test-done"))
    }

    private static func runHostSide(
        session: PeerHostSession,
        done: TestCompletionBox
    ) async {
        do {
            // Control: one request/response round trip.
            guard let request = try await session.controlTransport.receive() else {
                throw SessionFailure(reason: "host control ended early")
            }
            guard String(decoding: request, as: UTF8.self) == "rpc-request" else {
                throw SessionFailure(reason: "unexpected control request")
            }
            try await session.controlTransport.send(Data("rpc-response".utf8))

            // Application lane: expect the terminal lane, echo its bytes.
            var lanes = session.applicationLanes().makeAsyncIterator()
            guard let lane = await lanes.next() else {
                throw SessionFailure(reason: "no application lane arrived")
            }
            guard case let .terminal(resourceID, cursor, initialBytes, stream) = lane else {
                throw SessionFailure(reason: "expected terminal lane")
            }
            guard resourceID == "surface-1", cursor == 42 else {
                throw SessionFailure(reason: "wrong terminal lane identity")
            }
            var payload = initialBytes
            while let chunk = try await stream.read() {
                payload.append(chunk)
            }
            try await stream.write(Data("echo:".utf8) + payload)
            try await stream.finish()

            // Server-event lane back to the client.
            let events = try await session.openServerEventLane(cursor: 7)
            try await events.write(Data("event-payload".utf8))
            try await events.finish()

            await done.complete(with: .success(()))
        } catch {
            await done.complete(with: .failure(error))
        }
    }
}

/// One-slot box for handing the host session back to the test body.
actor TestSessionBox {
    private(set) var value: PeerHostSession?

    func store(_ session: PeerHostSession) {
        if value == nil {
            value = session
        }
    }
}
