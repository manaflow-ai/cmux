import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// Barrier-capable admission frames, mirrored locally so these tests can
/// drive a barrier-offering peer byte-accurately over the live QUIC
/// substrate independent of the production frame definitions.
private struct BarrierHello: Codable {
    var v: Int
    var proto: String
    var grant: String?
    var natBarrier: Bool?
}

private struct BarrierAdmit: Codable {
    var v: Int
    var session: String
    var keepaliveIntervalMs: Int
    var keepaliveDeadlineMs: Int
    var natBarrier: Bool?
}

private struct BarrierReady: Codable {
    var v: Int
}

/// NAT-traversal authorization barrier: a hello that offers `natBarrier`
/// must be acked in the admit, and the server must then hold admission open
/// until the client's ready frame proves the client authorized NAT traversal
/// first. Without this ordering the server's ADD_ADDRESS candidate frames
/// reach a not-yet-authorized client, which discards and tombstones them,
/// leaving the connection on relay forever.
@Suite("irx NAT barrier", .serialized)
struct IrxNatBarrierTests {
    @Test("server acks the barrier offer and defers admission until client-ready")
    func serverWaitsForClientReady() async throws {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> IrxAdmittedPeerInfo? in
            guard let incoming = await server.acceptNext() else { return nil }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(
                connection: connection, role: .acceptor, journal: journal)
            let result = await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            )
            return result?.0
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        let control = try await irx.openLane(IrxLaneDescriptor(lane: .control))
        try await control.writer.writeControlFrame(
            BarrierHello(
                v: IrxProtocol().version, proto: IrxProtocol().alpn,
                grant: "good-grant", natBarrier: true))
        let admit = try await control.reader.readControlFrame(BarrierAdmit.self)
        #expect(admit?.natBarrier == true)

        try await control.writer.writeControlFrame(BarrierReady(v: IrxProtocol().version))
        let peer = try await serverTask.value
        #expect(peer?.deviceID == "d-test")

        // Deterministic wait proof: the server read the ready frame this test
        // sent only after the admit, and recorded it before completing
        // admission. A server that admitted without waiting either never
        // records ready-received or records it after admitted.
        let events = journal.tail()
        let readyReceived = events.firstIndex {
            $0.event == "nat-barrier" && $0.attributes["state"] == "client-ready-received"
        }
        let serverAdmitted = events.firstIndex {
            $0.event == "admitted" && $0.attributes["device"] != nil
        }
        #expect(readyReceived != nil)
        #expect(serverAdmitted != nil)
        if let readyReceived, let serverAdmitted {
            #expect(readyReceived < serverAdmitted)
        }
        await irx.close(code: .userRequested, origin: .local)
    }

    @Test("legacy hello without the barrier capability admits immediately")
    func legacyClientAdmitsWithoutReady() async throws {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> IrxAdmittedPeerInfo? in
            guard let incoming = await server.acceptNext() else { return nil }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(
                connection: connection, role: .acceptor, journal: journal)
            let result = await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            )
            return result?.0
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        let control = try await irx.openLane(IrxLaneDescriptor(lane: .control))
        try await control.writer.writeControlFrame(IrxHello(grant: "good-grant"))
        let admit = try await control.reader.readControlFrame(BarrierAdmit.self)
        // A legacy hello must be admitted with no barrier ack and no ready wait.
        #expect(admit?.natBarrier == nil)
        let peer = try await serverTask.value
        #expect(peer?.deviceID == "d-test")
        await irx.close(code: .userRequested, origin: .local)
    }

    @Test("client offering the barrier authorizes first, then signals ready")
    func clientAuthorizesThenSignalsReady() async throws {
        let clientJournal = IrxLiveTestSupport.journal()
        let serverJournal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> (Bool?, IrxClientReady?) in
            guard let incoming = await server.acceptNext() else { return (nil, nil) }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(
                connection: connection, role: .acceptor, journal: serverJournal)
            guard let control = await irx.acceptLane(),
                let hello = try await control.reader.readControlFrame(BarrierHello.self)
            else { return (nil, nil) }
            try await control.writer.writeControlFrame(
                BarrierAdmit(
                    v: hello.v, session: "s-test", keepaliveIntervalMs: 5000,
                    keepaliveDeadlineMs: 2000, natBarrier: true))
            let ready = try await control.reader.readControlFrame(IrxClientReady.self)
            return (hello.natBarrier, ready)
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: clientJournal)
        let (admit, clientControl) = try await IrxAdmission().performClient(
            connection: irx, grantJWS: "good-grant", journal: clientJournal,
            authorizesDirectPaths: true)
        #expect(admit.natBarrier == true)
        let (offered, ready) = try await serverTask.value
        await clientControl.writer.reset(errorCode: 0)
        #expect(offered == true)
        #expect(ready != nil)
        // The client's own authorization must precede the ready signal.
        let events = clientJournal.tail().map(\.event)
        let authorizedIndex = events.firstIndex(of: "nat-traversal-authorized")
        let readyIndex = events.firstIndex(of: "nat-barrier")
        #expect(authorizedIndex != nil)
        #expect(readyIndex != nil)
        if let authorizedIndex, let readyIndex {
            #expect(authorizedIndex < readyIndex)
        }
        await irx.close(code: .userRequested, origin: .local)
    }

    @Test("client against a legacy server authorizes without sending ready")
    func clientLegacyServerFallback() async throws {
        let clientJournal = IrxLiveTestSupport.journal()
        let serverJournal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> Bool in
            guard let incoming = await server.acceptNext() else { return false }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(
                connection: connection, role: .acceptor, journal: serverJournal)
            guard let control = await irx.acceptLane(),
                try await control.reader.readControlFrame(BarrierHello.self) != nil
            else { return false }
            // Legacy admit: no barrier ack.
            try await control.writer.writeControlFrame(IrxAdmit(session: "s-legacy"))
            // The client must not send a ready frame at a legacy server.
            let readyResult = try await withIrxDeadlineResult(.milliseconds(400)) {
                try await control.reader.readControlFrame(IrxClientReady.self)
            }
            if case .timeout = readyResult { return true }
            return false
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: clientJournal)
        let (admit, clientControl) = try await IrxAdmission().performClient(
            connection: irx, grantJWS: "good-grant", journal: clientJournal,
            authorizesDirectPaths: true)
        #expect(admit.natBarrier == nil)
        // Keep the client's control lane alive so its deinit cannot EOF the
        // server's ready-frame read before the deadline elapses.
        let noReadyArrived = try await serverTask.value
        await clientControl.writer.reset(errorCode: 0)
        #expect(noReadyArrived)
        // The client still authorizes for itself so a direct upgrade stays
        // possible if the legacy server's candidates ever arrive post-grant.
        let events = clientJournal.tail().map(\.event)
        #expect(events.contains("nat-traversal-authorized"))
        await irx.close(code: .userRequested, origin: .local)
    }

    @Test("failed pre-authorization recheck aborts before authorizing or signaling")
    func preAuthorizationFailureAbortsWithoutDisclosure() async throws {
        struct StaleDial: Error {}
        let clientJournal = IrxLiveTestSupport.journal()
        let serverJournal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> Bool in
            guard let incoming = await server.acceptNext() else { return false }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(
                connection: connection, role: .acceptor, journal: serverJournal)
            guard let control = await irx.acceptLane(),
                try await control.reader.readControlFrame(BarrierHello.self) != nil
            else { return false }
            try await control.writer.writeControlFrame(
                BarrierAdmit(
                    v: 1, session: "s-stale", keepaliveIntervalMs: 5000,
                    keepaliveDeadlineMs: 2000, natBarrier: true))
            // The aborting client must never send ready; its abandoned lane
            // may surface as EOF, which is equally "no ready arrived".
            let readyResult = try? await withIrxDeadlineResult(.milliseconds(400)) {
                try await control.reader.readControlFrame(IrxClientReady.self)
            }
            if case .operation(.some) = readyResult ?? .timeout { return false }
            return true
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: clientJournal)
        await #expect(throws: StaleDial.self) {
            _ = try await IrxAdmission().performClient(
                connection: irx, grantJWS: "good-grant", journal: clientJournal,
                authorizesDirectPaths: true,
                preAuthorization: { throw StaleDial() })
        }
        let noReadyArrived = try await serverTask.value
        #expect(noReadyArrived)
        // The abort happened before any NAT-traversal authorization.
        let events = clientJournal.tail().map(\.event)
        #expect(!events.contains("nat-traversal-authorized"))
        await irx.close(code: .userRequested, origin: .local)
    }

    @Test("real admission halves complete the barrier and order authorization")
    func fullAdmissionOrdersAuthorization() async throws {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> IrxAdmittedPeerInfo? in
            guard let incoming = await server.acceptNext() else { return nil }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(
                connection: connection, role: .acceptor, journal: journal)
            let result = await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            )
            return result?.0
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        let (admit, clientControl) = try await IrxAdmission().performClient(
            connection: irx, grantJWS: "good-grant", journal: journal,
            authorizesDirectPaths: true)
        #expect(admit.natBarrier == true)
        let peer = try await serverTask.value
        await clientControl.writer.reset(errorCode: 0)
        #expect(peer?.deviceID == "d-test")

        // Shared journal: the client's authorization must precede the
        // server's admitted record (the server-side event carries "device").
        let events = journal.tail()
        let clientAuthorized = events.firstIndex {
            $0.event == "nat-traversal-authorized"
        }
        let serverAdmitted = events.firstIndex {
            $0.event == "admitted" && $0.attributes["device"] != nil
        }
        #expect(clientAuthorized != nil)
        #expect(serverAdmitted != nil)
        if let clientAuthorized, let serverAdmitted {
            #expect(clientAuthorized < serverAdmitted)
        }
        await irx.close(code: .userRequested, origin: .local)
    }
}
