import Foundation
import Testing

@testable import CmuxPeerTransport

/// Live QUIC over 127.0.0.1: the full core stack (bind, dial, admission,
/// raw streams, supersession, reconnect) with no relays and no app.
@Suite(.serialized) struct PtxLoopbackTests {
    private static func makeLog() -> PtxEventLog {
        PtxEventLog(subsystem: "dev.cmux.ptx.tests", category: "loopback", fileURL: nil)
    }

    private struct Rig {
        let log: PtxEventLog
        let hostIdentity: PtxIdentity
        let clientIdentity: PtxIdentity
        let signer: PtxGrantSigner
        let host: PtxHost
        let hostEndpoint: IrohEndpointBox
        let ticket: PtxTicket
        let admitted: AsyncStream<PtxHostSession>

        func close() async {
            await host.stop()
            try? await hostEndpoint.endpoint.close()
        }
    }

    private static func makeRig() async throws -> Rig {
        let log = makeLog()
        let hostIdentity = PtxIdentity.generate(deviceID: "mac-1", appIdentity: "test.host")
        let clientIdentity = PtxIdentity.generate(deviceID: "phone-1", appIdentity: "test.ios")
        let signer = try PtxGrantSigner(
            privateKeyData: PtxIdentity.generate(deviceID: "x", appIdentity: "x").privateKeyData)
        let (admittedStream, admittedContinuation) = AsyncStream.makeStream(
            of: PtxHostSession.self)
        let host = PtxHost(
            identity: hostIdentity, signer: signer, log: log,
            onAdmitted: { session in admittedContinuation.yield(session) })
        let endpoint = try await PtxEndpoint.bind(
            identity: hostIdentity, relays: [], loopbackOnly: true)
        await host.serve(endpoint: IrohEndpointBox(endpoint: endpoint))
        let addr = PtxEndpoint.directAddr(of: endpoint)
        let ticket = PtxTicket(
            hostEndpointKey: hostIdentity.publicKeyData,
            hostSignerKey: signer.publicKeyData,
            hostDeviceID: hostIdentity.deviceID,
            relayURL: nil,
            directAddresses: addr.directAddresses())
        return Rig(
            log: log, hostIdentity: hostIdentity, clientIdentity: clientIdentity,
            signer: signer, host: host, hostEndpoint: IrohEndpointBox(endpoint: endpoint),
            ticket: ticket, admitted: admittedStream)
    }

    private static func clientEndpoint(_ rig: Rig) async throws -> IrohEndpointBox {
        IrohEndpointBox(
            endpoint: try await PtxEndpoint.bind(
                identity: rig.clientIdentity, relays: [], loopbackOnly: true))
    }

    private static func mintClientGrant(_ rig: Rig) async throws -> PtxGrant {
        try await rig.host.mintGrant(
            account: "test@example.com",
            deviceID: rig.clientIdentity.deviceID,
            devicePublicKey: rig.clientIdentity.publicKeyData,
            appIdentity: rig.clientIdentity.appIdentity)
    }

    @Test func admissionAndRawStreamRoundTrip() async throws {
        let rig = try await Self.makeRig()
        defer { Task { await rig.close() } }
        let client = try await Self.clientEndpoint(rig)
        let grant = try await Self.mintClientGrant(rig)

        let outcome = try await PtxClient.connect(
            endpoint: client.endpoint,
            plan: PtxClient.DialPlan(ticket: rig.ticket, relayOnly: false),
            identity: rig.clientIdentity, grant: grant, log: rig.log)
        guard case .admitted(let session) = outcome else {
            Issue.record("expected admission, got \(outcome)")
            return
        }
        var iterator = rig.admitted.makeAsyncIterator()
        let hostSession = await iterator.next()
        #expect(hostSession != nil)

        // Raw stream client -> host with bytes racing the handshake frame:
        // write immediately so remainder handling gets exercised.
        let raw = try await session.connection.openRawStream(descriptor: "{\"lane\":\"terminal\"}")
        let payload = Data("hello-across-the-handshake".utf8)
        try await raw.write(payload)

        let received = await withCheckedContinuation {
            (continuation: CheckedContinuation<Data, Never>) in
            Task {
                await hostSession!.connection.onRawStream { descriptor, stream in
                    var buffer = stream.handshakeRemainder
                    var collected = Data()
                    while collected.count < payload.count {
                        guard
                            let chunk = try? await stream.read(
                                maximumByteCount: 1 << 16, consumedBuffer: &buffer)
                        else { break }
                        collected.append(chunk)
                    }
                    continuation.resume(returning: collected)
                }
            }
        }
        #expect(received == payload)
        await session.connection.close(reason: PtxCloseReason.userRequested.rawValue)
    }

    @Test func wrongSignerIsDeniedWithNamedReason() async throws {
        let rig = try await Self.makeRig()
        defer { Task { await rig.close() } }
        let client = try await Self.clientEndpoint(rig)
        let rogueSigner = try PtxGrantSigner(
            privateKeyData: PtxIdentity.generate(deviceID: "r", appIdentity: "r").privateKeyData)
        let rogueGrant = try rogueSigner.mint(
            account: "test@example.com", deviceID: rig.clientIdentity.deviceID,
            devicePublicKey: rig.clientIdentity.publicKeyData,
            appIdentity: rig.clientIdentity.appIdentity, lifetime: 3600)

        let outcome = try await PtxClient.connect(
            endpoint: client.endpoint,
            plan: PtxClient.DialPlan(ticket: rig.ticket, relayOnly: false),
            identity: rig.clientIdentity, grant: rogueGrant, log: rig.log)
        guard case .denied(let code) = outcome else {
            Issue.record("expected denial, got admission")
            return
        }
        #expect(code == PtxDenial.invalidSignature.rawValue)
    }

    @Test func sameDeviceSupersedesImmediately() async throws {
        let rig = try await Self.makeRig()
        defer { Task { await rig.close() } }
        let client = try await Self.clientEndpoint(rig)
        let grant = try await Self.mintClientGrant(rig)
        let plan = PtxClient.DialPlan(ticket: rig.ticket, relayOnly: false)

        let first = try await PtxClient.connect(
            endpoint: client.endpoint, plan: plan, identity: rig.clientIdentity,
            grant: grant, log: rig.log)
        guard case .admitted(let firstSession) = first else {
            Issue.record("first connect not admitted")
            return
        }
        let second = try await PtxClient.connect(
            endpoint: client.endpoint, plan: plan, identity: rig.clientIdentity,
            grant: grant, log: rig.log)
        guard case .admitted = second else {
            Issue.record("second connect not admitted")
            return
        }
        // The first session must end with the superseded reason, promptly.
        let reason = await firstSession.connection.termination()
        #expect(reason == PtxCloseReason.superseded.rawValue)
        let count = await rig.host.activeSessionCount()
        #expect(count == 1)
    }

    @Test func ownerRedialsAutomaticallyAfterHostKill() async throws {
        let rig = try await Self.makeRig()
        defer { Task { await rig.close() } }
        let client = try await Self.clientEndpoint(rig)
        let grant = try await Self.mintClientGrant(rig)
        let plan = PtxClient.DialPlan(ticket: rig.ticket, relayOnly: false)

        let (states, statesContinuation) = AsyncStream.makeStream(of: PtxOwnerState.self)
        let owner = PtxReconnectOwner(
            log: rig.log,
            connect: { [clientIdentity = rig.clientIdentity, log = rig.log] in
                try await PtxClient.connect(
                    endpoint: client.endpoint, plan: plan, identity: clientIdentity,
                    grant: grant, log: log)
            },
            onStateChange: { state in statesContinuation.yield(state) })
        await owner.trigger(.automatic("launch"))

        var iterator = states.makeAsyncIterator()
        var sawReadyOnce = false
        var readyAgainAfterKill = false
        var killed = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            guard let state = await iterator.next() else { break }
            if case .ready = state {
                if !sawReadyOnce {
                    sawReadyOnce = true
                    // Kill from the host side with an UNattributed close shape
                    // (network-death stand-in): close the host's session
                    // connection directly.
                    if !killed {
                        killed = true
                        var admittedIterator = rig.admitted.makeAsyncIterator()
                        let hostSession = await admittedIterator.next()
                        Task { await hostSession?.connection.close(reason: nil) }
                    }
                } else {
                    readyAgainAfterKill = true
                    break
                }
            }
        }
        #expect(sawReadyOnce)
        #expect(readyAgainAfterKill)
        await owner.stop(reason: "test-over")
    }
}
