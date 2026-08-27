import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// Live-QUIC substrate tests: two real iroh endpoints over loopback (no
/// relay), exercising the actual wire protocol end to end. These pin the
/// behaviors the soak depends on: one-round-trip admission, reasoned denials,
/// raw lane passthrough, keepalive ping/pong, supersession, and the engine's
/// automatic redial after a host-side close.
enum IrxLiveTestSupport {
    static func journal() -> IrxJournal {
        IrxJournal(subsystem: "dev.cmux.tests", category: "irx-live")
    }

    static func bindLoopback(
        seed: Data,
        remoteBiCredit: UInt64
    ) async throws -> Endpoint {
        let options = EndpointOptions(
            preset: presetMinimal(),
            bindAddr: "127.0.0.1:0",
            secretKey: seed,
            alpns: [IrxProtocol.alpnData],
            relayMode: RelayMode.disabled(),
            portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: false,
            initialMaxConcurrentBiStreams: remoteBiCredit,
            initialMaxConcurrentUniStreams: 0
        )
        return try await Endpoint.bind(options: options)
    }

    static func loopbackAddr(of endpoint: Endpoint) -> EndpointAddr {
        let addresses = endpoint.boundSockets().map {
            $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        }
        return EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: addresses)
    }

    static func identitySeed() -> Data {
        var seed = Data(count: 32)
        for index in 0..<32 {
            seed[index] = UInt8.random(in: 0...255)
        }
        return seed
    }

    /// A judgment that admits exactly one grant string.
    static func fixedJudgment(accepting grant: String) -> IrxGrantJudgment {
        { presented, remoteHex in
            guard presented == grant else {
                throw IrxAdmissionDenied(code: .invalidGrant)
            }
            return IrxAdmittedPeerInfo(
                bindingID: "b-test",
                deviceID: "d-test",
                tag: "t-test",
                endpointIDHex: remoteHex,
                identityGeneration: 1
            )
        }
    }
}

@Suite("live QUIC", .serialized)
struct IrxLiveQUICTests {
    @Test("admission admits a valid grant in one round trip and lanes carry raw bytes")
    func admissionAndLanes() async throws {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task { () -> (IrxAdmittedPeerInfo, IrxLaneStream, String)? in
            guard let incoming = await server.acceptNext() else { return nil }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(connection: connection, role: .acceptor, journal: journal)
            guard
                let admitted = await IrxAdmission.performServer(
                    connection: irx,
                    judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                    journal: journal
                )
            else { return nil }
            // Echo service: accept one lane, echo its descriptor + bytes.
            if let lane = await irx.acceptLane() {
                #expect(lane.descriptor.lane == .terminal)
                #expect(lane.descriptor.cursor == 7)
                let payload = try await lane.reader.readRaw()
                try await lane.writer.write(payload ?? Data())
                await lane.writer.finish()
            }
            return admitted
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol.alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        let (admit, _) = try await IrxAdmission.performClient(
            connection: irx, grantJWS: "good-grant", journal: journal)
        #expect(!admit.session.isEmpty)

        let lane = try await irx.openLane(
            IrxLaneDescriptor(lane: .terminal, resource: "terminal:test", cursor: 7))
        let sent = Data("raw bytes ride lanes unframed".utf8)
        try await lane.writer.write(sent)
        var received = Data()
        while let chunk = try await lane.reader.readRaw() {
            received.append(chunk)
            if received.count >= sent.count { break }
        }
        #expect(received == sent)

        let serverAdmitted = try await serverTask.value
        #expect(serverAdmitted?.0.deviceID == "d-test")
        await irx.close(code: .userRequested, origin: .local)
        try? await server.close()
        try? await client.close()
    }

    @Test("a denied grant surfaces its machine-readable code via the termination")
    func denialSurfacesCode() async throws {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let serverTask = Task {
            guard let incoming = await server.acceptNext() else { return }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(connection: connection, role: .acceptor, journal: journal)
            _ = await IrxAdmission.performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            )
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol.alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        do {
            _ = try await IrxAdmission.performClient(
                connection: irx, grantJWS: "stolen-grant", journal: journal)
            Issue.record("admission unexpectedly succeeded")
        } catch let denial as IrxAdmissionDenied {
            #expect(denial.code == .invalidGrant)
        }
        try await serverTask.value
        try? await server.close()
        try? await client.close()
    }

    @Test("keepalive ping/pong flows and death triggers the engine's instant redial")
    func keepaliveAndAutoRedial() async throws {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let registry = IrxServerSessionRegistry(journal: journal)

        // Server: admit every connection, run keepalive responders, register
        // for supersession.
        let serverLoop = Task {
            while let incoming = await server.acceptNext() {
                let accepting = try await incoming.accept()
                let connection = try await accepting.connect()
                let irx = IrxConnection(
                    connection: connection, role: .acceptor, journal: journal)
                guard
                    let (peer, _, sessionID) = await IrxAdmission.performServer(
                        connection: irx,
                        judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                        journal: journal
                    )
                else { continue }
                await registry.admit(
                    deviceID: peer.deviceID, sessionID: sessionID, connection: irx)
                Task {
                    while let lane = await irx.acceptLane() {
                        if lane.descriptor.lane == .keepalive {
                            _ = irx.respondKeepalive(on: lane)
                        }
                    }
                }
            }
        }

        let dialAddr = IrxLiveTestSupport.loopbackAddr(of: server)
        let engine = IrxPeerEngine(
            config: .init(initialBackoff: .milliseconds(50), maxBackoff: .milliseconds(400)),
            journal: journal
        ) {
            let connection = try await client.connect(
                addr: dialAddr, alpn: IrxProtocol.alpnData)
            let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
            let (admit, control) = try await IrxAdmission.performClient(
                connection: irx, grantJWS: "good-grant", journal: journal)
            return IrxClientSession(
                connection: irx, admit: admit, control: control, establishedAt: Date())
        }

        let first = try await engine.ensureSession(trigger: "test")
        // Keepalive proves liveness within one interval (5s) + deadline: wait
        // for the first pong instead of sleeping a fixed span, so the
        // assertion tracks the real event.
        let pongDeadline = ContinuousClock.now + .seconds(8)
        while journal.counterSnapshot()["pong"] ?? 0 < 1, ContinuousClock.now < pongDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await !first.connection.isClosed)
        #expect(journal.counterSnapshot()["pong"] ?? 0 >= 1)

        // Host closes (e.g. shutdown): the engine must redial by itself and
        // reach ready again without any external trigger.
        await first.connection.close(code: .hostShutdown, origin: .remote)
        var recovered: IrxClientSession?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if let session = await engine.currentSession(),
                session.admit.session != first.admit.session
            {
                recovered = session
                break
            }
        }
        #expect(recovered != nil, "engine did not auto-redial after host close")

        // Supersession: a second dial from the same device replaces the first
        // session on the server registry.
        #expect(await registry.activeSessionCount == 1)

        await engine.stop()
        serverLoop.cancel()
        try? await server.close()
        try? await client.close()
    }
}
