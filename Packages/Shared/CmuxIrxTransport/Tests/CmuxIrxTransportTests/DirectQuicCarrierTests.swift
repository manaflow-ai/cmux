import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrxTransport

/// irx over Network.framework QUIC on loopback: device-key handshake,
/// admission, lanes, and attributed closes, with no Iroh endpoint involved.
@Suite(.timeLimit(.minutes(1)))
struct DirectQuicCarrierTests {
    private static func identity(_ name: String) -> IrxIdentity {
        IrxIdentity(privateKeyData: IrxLiveTestSupport.identitySeed(), deviceID: name, appInstanceID: name)
    }

    private static func listener(_ identity: IrxIdentity) async throws -> (DirectQuicListener, UInt16)? {
        guard #available(macOS 15.0, *) else { return nil }
        let listener = try DirectQuicListener(port: 0, identity: identity)
        return (listener, try await listener.start())
    }

    @Test func handshakeAuthenticatesBothDeviceKeys() async throws {
        let mac = Self.identity("mac"), phone = Self.identity("phone")
        guard let (listener, port) = try await Self.listener(mac) else { return }
        defer { listener.cancel() }
        let accepted = Task { await listener.connections.first { _ in true } }

        let client = try await DirectQuicCarrierConnection.dial(
            host: "127.0.0.1", port: port, identity: phone, expectedEndpointIDHex: mac.endpointIDHex)
        let server = try #require(await accepted.value)

        #expect(client.remoteEndpointIDHex == mac.endpointIDHex)
        #expect(server.remoteEndpointIDHex == phone.endpointIDHex)
        client.close(errorCode: 1, reason: IrxCloseCode.userRequested.reasonData)
    }

    @Test func dialRejectsAMacWithAnotherKey() async throws {
        let mac = Self.identity("mac"), impostorExpected = Self.identity("other-mac")
        guard let (listener, port) = try await Self.listener(mac) else { return }
        defer { listener.cancel() }

        await #expect(throws: DirectQuicError.peerIdentityMismatch) {
            _ = try await DirectQuicCarrierConnection.dial(
                host: "127.0.0.1", port: port, identity: Self.identity("phone"),
                expectedEndpointIDHex: impostorExpected.endpointIDHex)
        }
    }

    @Test func irxAdmissionLanesAndAttributedCloseRunOverTheCarrier() async throws {
        let mac = Self.identity("mac"), phone = Self.identity("phone")
        guard let (listener, port) = try await Self.listener(mac) else { return }
        defer { listener.cancel() }
        let journal = IrxLiveTestSupport.journal()
        let judgedKeys = IrxJudgedKeys()

        let serverTask = Task { () -> (IrxConnection, IrxLaneStream)? in
            guard let carrier = await listener.connections.first(where: { _ in true }) else { return nil }
            let irx = IrxConnection(carrier: carrier, role: .acceptor, journal: journal)
            guard let (_, control, _) = await IrxAdmission().performServer(
                connection: irx,
                judgment: { _, endpoint in
                    judgedKeys.record(endpoint)
                    return IrxAdmittedPeerInfo(bindingID: "binding", deviceID: "phone", tag: "",
                        endpointIDHex: endpoint, identityGeneration: 1)
                },
                journal: journal)
            else { return nil }
            return (irx, control)
        }

        let carrier = try await DirectQuicCarrierConnection.dial(
            host: "127.0.0.1", port: port, identity: phone, expectedEndpointIDHex: mac.endpointIDHex)
        let client = IrxConnection(carrier: carrier, role: .dialer, journal: journal)
        let (admit, clientControl) = try await IrxAdmission().performClient(connection: client, journal: journal)
        let (server, serverControl) = try #require(await serverTask.value)
        #expect(!admit.session.isEmpty)
        #expect(judgedKeys.values == [phone.endpointIDHex])

        // Control lane carries raw bytes both ways after admission.
        try await clientControl.writer.write(Data("ping".utf8))
        #expect(try await serverControl.reader.readRaw() == Data("ping".utf8))
        try await serverControl.writer.write(Data("pong".utf8))
        #expect(try await clientControl.reader.readRaw() == Data("pong".utf8))

        // A client-opened terminal lane arrives with its descriptor.
        let accepting = Task { await server.acceptLane() }
        let lane = try await client.openLane(IrxLaneDescriptor(lane: .terminal, resource: "terminal:1", cursor: 7))
        let acceptedLane = try #require(await accepting.value)
        #expect(acceptedLane.descriptor.resource == "terminal:1")
        #expect(acceptedLane.descriptor.cursor == 7)
        try await lane.writer.write(Data("input".utf8))
        #expect(try await acceptedLane.reader.readRaw() == Data("input".utf8))
        // Closing a lane ends only that lane; the peer reads end-of-stream.
        await lane.close()
        #expect(try await acceptedLane.reader.readRaw() == nil)

        // The server's one-way events lane reaches the client.
        let events = try await server.openUniLane(IrxLaneDescriptor(lane: .events))
        let (eventsDescriptor, eventsReader) = try #require(try await client.acceptUniLane())
        #expect(eventsDescriptor.lane == .events)
        try await events.write(Data("event".utf8))
        #expect(try await eventsReader.readRaw() == Data("event".utf8))

        // Keepalive probes round-trip through the server responder.
        let responder = Task { () -> Task<Void, Never>? in
            guard let keepalive = await server.acceptLane() else { return nil }
            return server.respondKeepalive(on: keepalive)
        }
        #expect(await client.probeLiveness(deadline: .seconds(5)))
        (await responder.value)?.cancel()

        // The close code reaches the peer as a remote termination.
        await server.close(code: .revoked, origin: .local)
        let closedAt = ContinuousClock.now
        await client.waitForClosure(observationID: await client.makeClosureObservationID())
        #expect(ContinuousClock.now - closedAt < .seconds(2))
        #expect(await client.termination() == IrxTermination(origin: .remote, code: IrxCloseCode.revoked.rawValue))
    }

    /// F3 regression: a canceled inbox waiter must not swallow the next lane.
    @Test func cancelledLaneWaiterDoesNotStealTheNextLane() async throws {
        let mac = Self.identity("mac"), phone = Self.identity("phone")
        guard let (listener, port) = try await Self.listener(mac) else { return }
        defer { listener.cancel() }
        let accepted = Task { await listener.connections.first { _ in true } }
        let client = try await DirectQuicCarrierConnection.dial(
            host: "127.0.0.1", port: port, identity: phone, expectedEndpointIDHex: mac.endpointIDHex)
        let server = try #require(await accepted.value)

        let abandoned = Task { try await client.acceptUni() }
        try await Task.sleep(for: .milliseconds(50))
        abandoned.cancel()
        await #expect(throws: (any Error).self) { _ = try await abandoned.value }

        let events = try await server.openUni()
        try await events.writeAll(Data([9]))
        // The canceled waiter is gone; a live waiter receives the lane.
        let received = try await client.acceptUni()
        #expect(try await received.read(sizeLimit: 8) == Data([9]))
        client.close(errorCode: 1, reason: IrxCloseCode.userRequested.reasonData)
    }

    /// F2 regression: a connection occupies an admission slot until its irx
    /// verdict settles it, so unjudged dialers cannot pile up unbounded.
    @Test func admissionSlotHeldUntilVerdictBoundsUnjudgedConnections() async throws {
        let mac = Self.identity("mac")
        guard #available(macOS 15.0, *) else { return }
        let listener = try DirectQuicListener(port: 0, identity: mac, maximumPendingAdmissions: 1)
        let port = try await listener.start()
        defer { listener.cancel() }
        let accepted = Task { await listener.connections.first { _ in true } }

        let first = try await DirectQuicCarrierConnection.dial(
            host: "127.0.0.1", port: port, identity: Self.identity("phone-1"),
            expectedEndpointIDHex: mac.endpointIDHex)
        let serverSide = try #require(await accepted.value)

        // The slot is still held: a second dial cannot complete its handshake.
        await #expect(throws: (any Error).self) {
            _ = try await DirectQuicCarrierConnection.dial(
                host: "127.0.0.1", port: port, identity: Self.identity("phone-2"),
                expectedEndpointIDHex: mac.endpointIDHex, deadline: .seconds(2))
        }

        serverSide.settleAdmission()
        let third = try await DirectQuicCarrierConnection.dial(
            host: "127.0.0.1", port: port, identity: Self.identity("phone-3"),
            expectedEndpointIDHex: mac.endpointIDHex)
        #expect(third.remoteEndpointIDHex == mac.endpointIDHex)
        first.close(errorCode: 1, reason: IrxCloseCode.userRequested.reasonData)
        third.close(errorCode: 1, reason: IrxCloseCode.userRequested.reasonData)
    }
}

private final class IrxJudgedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ key: String) { lock.withLock { recorded.append(key) } }
    var values: [String] { lock.withLock { recorded } }
}
