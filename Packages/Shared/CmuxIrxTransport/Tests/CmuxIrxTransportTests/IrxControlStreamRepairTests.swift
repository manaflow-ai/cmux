import CMUXMobileCore
import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// Two real iroh endpoints over loopback. The host side runs the same
/// transport and lane handling the Mac runs; the client side is the phone's
/// control transport.
private struct AdmittedPair {
    let server: Endpoint
    let client: Endpoint
    let clientConnection: IrxConnection
    let clientControl: IrxLaneStream
    let serverConnection: IrxConnection
    let serverControl: IrxLaneStream

    static func make() async throws -> AdmittedPair {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> (IrxConnection, IrxLaneStream)? in
            guard let incoming = await server.acceptNext() else { return nil }
            let native = try await incoming.accept().connect()
            let irx = IrxConnection(connection: native, role: .acceptor, journal: journal)
            guard let (_, control, _) = await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            ) else { return nil }
            return (irx, control)
        }
        let native = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: native, role: .dialer, journal: journal)
        let (_, control) = try await IrxAdmission().performClient(
            connection: irx, grantJWS: "good-grant", journal: journal)
        let (serverConnection, serverControl) = try #require(try await serverTask.value)
        return AdmittedPair(
            server: server,
            client: client,
            clientConnection: irx,
            clientControl: control,
            serverConnection: serverConnection,
            serverControl: serverControl
        )
    }

    func shutDown() async {
        await clientConnection.close(code: .userRequested, origin: .local)
        await serverConnection.close(code: .userRequested, origin: .local)
        try? await server.close()
        try? await client.close()
    }
}

/// The Mac's post-admission lane handling for control replacements.
private func serveControlReplacements(
    on connection: IrxConnection,
    host: IrxControlByteTransport
) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled, let lane = await connection.acceptLane() {
            if lane.descriptor.lane == .controlRepair {
                await host.acceptControlLaneReplacement(lane)
            }
        }
    }
}

private func frame(_ text: String) throws -> Data {
    try MobileSyncFrameCodec.encodeFrame(Data(text.utf8))
}

@Suite("control stream repair", .serialized)
struct IrxControlStreamRepairTests {
    @Test("a silent control stream is replaced on the same connection", .timeLimit(.minutes(1)))
    func silentStreamIsReplacedWithoutClosingTheConnection() async throws {
        let pair = try await AdmittedPair.make()
        let phone = IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { (pair.clientConnection, pair.clientControl) }
        )
        let host = IrxControlByteTransport(
            connection: pair.serverConnection, control: pair.serverControl, closeCode: .hostShutdown)
        try await phone.connect()
        try await host.connect()
        let lanes = serveControlReplacements(on: pair.serverConnection, host: host)
        let stableID = pair.clientConnection.underlying.stableId()

        // Both ends are already parked reading the stream being replaced,
        // which is where a silent stream leaves them.
        let hostRead = Task { try await host.receive() }
        let phoneRead = Task { try await phone.receive() }
        try await Task.sleep(for: .milliseconds(100))

        let outcome = await phone.repairControlStream(silentSince: .now)
        #expect(outcome == .repaired(generation: 1))

        let request = try frame(#"{"id":"after-repair"}"#)
        #expect(try await phone.sendReportingControlStreamGeneration(request) == 1)
        #expect(try await hostRead.value == request)
        let response = try frame(#"{"id":"after-repair","ok":true}"#)
        try await host.send(response)
        #expect(try await phoneRead.value == response)

        #expect(await !pair.clientConnection.isConnectionClosed())
        #expect(await !pair.serverConnection.isConnectionClosed())
        #expect(pair.clientConnection.underlying.stableId() == stableID)
        #expect(await phone.isTransportClosed() == false)

        lanes.cancel()
        await pair.shutDown()
    }

    @Test("a frame cut off by the replacement is dropped, not spliced", .timeLimit(.minutes(1)))
    func partialFrameOnTheRetiredStreamIsDropped() async throws {
        let pair = try await AdmittedPair.make()
        let phone = IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { (pair.clientConnection, pair.clientControl) }
        )
        let host = IrxControlByteTransport(
            connection: pair.serverConnection, control: pair.serverControl, closeCode: .hostShutdown)
        try await phone.connect()
        try await host.connect()
        let lanes = serveControlReplacements(on: pair.serverConnection, host: host)

        // Half a frame reaches the phone on the stream about to be replaced.
        let cutOff = try frame(#"{"id":"cut-off","padding":"0123456789"}"#)
        try await pair.serverControl.writer.write(cutOff.prefix(cutOff.count / 2))
        let phoneRead = Task { try await phone.receive() }
        try await Task.sleep(for: .milliseconds(200))

        #expect(await phone.repairControlStream(silentSince: .now) == .repaired(generation: 1))
        let whole = try frame(#"{"id":"whole"}"#)
        try await host.send(whole)
        #expect(try await phoneRead.value == whole)

        lanes.cancel()
        await pair.shutDown()
    }

    @Test("a host that predates replacement leaves the connection and the old stream alone",
          .timeLimit(.minutes(1)))
    func olderHostRefusesAndTheConnectionStays() async throws {
        let pair = try await AdmittedPair.make()
        let phone = IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { (pair.clientConnection, pair.clientControl) }
        )
        try await phone.connect()
        // An older host cannot decode the descriptor and resets the stream.
        let lanes = Task {
            while let stream = try? await pair.serverConnection.underlying.acceptBi() {
                try? await stream.send().reset(errorCode: 2)
                try? await stream.recv().stop(errorCode: 2)
            }
        }

        #expect(await phone.repairControlStream(silentSince: .now) == .unavailable)
        #expect(await !pair.clientConnection.isConnectionClosed())

        // The original stream still carries the session.
        let request = try frame(#"{"id":"still-here"}"#)
        #expect(try await phone.sendReportingControlStreamGeneration(request) == 0)
        var received = Data()
        while received.count < request.count,
              let chunk = try await pair.serverControl.reader.readRaw() {
            received.append(chunk)
        }
        #expect(received == request)

        lanes.cancel()
        await pair.shutDown()
    }

    @Test("no answer without evidence of whole-connection silence is not a death sentence",
          .timeLimit(.minutes(1)))
    func unansweredReplacementWithoutEvidenceIsUnavailable() async throws {
        let pair = try await AdmittedPair.make()
        let phone = IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { (pair.clientConnection, pair.clientControl) },
            controlRepairDeadline: .milliseconds(300)
        )
        try await phone.connect()
        // The host accepts streams but never acknowledges a replacement, and
        // no keepalive probes run, so nothing proves the connection is dead.
        let lanes = Task {
            while !Task.isCancelled, await pair.serverConnection.acceptLane() != nil {}
        }

        #expect(await phone.repairControlStream(silentSince: .now) == .unavailable)
        #expect(await !pair.clientConnection.isConnectionClosed())
        #expect(await phone.isTransportClosed() == false)

        lanes.cancel()
        await pair.shutDown()
    }

    @Test("a closed connection is positive evidence of silence", .timeLimit(.minutes(1)))
    func closedConnectionIsSilent() async throws {
        let pair = try await AdmittedPair.make()
        let phone = IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { (pair.clientConnection, pair.clientControl) }
        )
        try await phone.connect()
        await pair.serverConnection.close(code: .hostShutdown, origin: .local)
        _ = await pair.clientConnection.underlying.closed()

        #expect(await phone.repairControlStream(silentSince: .now) == .connectionSilent)

        await pair.shutDown()
    }

    @Test("probes that run unanswered for two full cycles are positive evidence of silence",
          .timeLimit(.minutes(1)))
    func unansweredProbesProveSilence() async throws {
        let pair = try await AdmittedPair.make()
        let phone = IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { (pair.clientConnection, pair.clientControl) },
            controlRepairDeadline: .milliseconds(200)
        )
        try await phone.connect()
        // The host process is wedged: its QUIC stack still accepts streams,
        // but nothing at the application layer answers.
        try await pair.clientConnection.startClientKeepalive(
            interval: .milliseconds(50), deadline: .milliseconds(50)
        ) {}
        try await Task.sleep(for: .milliseconds(20))
        let silentSince = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(300))
        #expect(await pair.clientConnection.applicationSilenceEvidence(since: silentSince) == .silent)
        #expect(await phone.repairControlStream(silentSince: silentSince) == .connectionSilent)

        await pair.shutDown()
    }

    @Test("application bytes on any lane count as activity; closure counts as silence")
    func silenceEvidenceComesFromApplicationBytes() async throws {
        let pair = try await AdmittedPair.make()
        let start = ContinuousClock.now
        // Without running probes, silence proves nothing.
        #expect(await pair.clientConnection.applicationSilenceEvidence(since: start) == .inconclusive)

        let lane = try await pair.clientConnection.openLane(IrxLaneDescriptor(lane: .keepalive))
        let responder = Task {
            if let accepted = await pair.serverConnection.acceptLane() {
                _ = pair.serverConnection.respondKeepalive(on: accepted)
            }
        }
        try await lane.writer.writeControlFrame(IrxPing(seq: 1, pong: false))
        _ = try await lane.reader.readControlFrame(IrxPing.self)
        #expect(await pair.clientConnection.applicationSilenceEvidence(since: start) == .activity)

        responder.cancel()
        await pair.clientConnection.close(code: .userRequested, origin: .local)
        #expect(await pair.clientConnection.applicationSilenceEvidence(since: .now) == .silent)
        await pair.shutDown()
    }
}
