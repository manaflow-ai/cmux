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
        let admitted = IrxAsyncLatch()
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
            await admitted.signal()
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

        // Admission must stay open until the client signals ready.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await admitted.isSignaled() == false)

        try await control.writer.writeControlFrame(BarrierReady(v: IrxProtocol().version))
        let peer = try await serverTask.value
        #expect(peer?.deviceID == "d-test")
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
}
