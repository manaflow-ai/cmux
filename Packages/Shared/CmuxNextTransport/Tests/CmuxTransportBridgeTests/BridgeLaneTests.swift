import CmuxIrohTransport
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import IrohLib
import Testing

@Suite("Lane descriptor codec")
struct BridgeLaneDescriptorTests {
    @Test("Every lane round-trips through its preamble")
    func roundTrip() throws {
        let terminalID = try CmxIrohResourceID("terminal:0a1b")
        let artifactID = try CmxIrohResourceID("artifact.7")
        let simID = try CmxIrohResourceID("simstream:9f")
        let lanes: [CmxIrohLane] = [
            .control,
            .serverEvents(cursor: nil),
            .serverEvents(cursor: 42),
            .terminal(resourceID: terminalID, cursor: nil),
            .terminal(resourceID: terminalID, cursor: 7),
            .artifact(resourceID: artifactID, offset: 1024),
            .simulatorStream(resourceID: simID),
        ]
        for lane in lanes {
            let preamble = try BridgeLaneDescriptor.preamble(for: lane)
            let decoded = try BridgeLaneDescriptor.lane(fromPreamble: preamble)
            #expect(decoded == lane)
        }
    }

    @Test("Garbage, wrong kinds, and missing fields are invalid")
    func invalidDescriptors() {
        let bad = [
            "not json",
            "{}",
            "{\"lane\":\"nope\"}",
            "{\"lane\":\"terminal\"}",
            "{\"lane\":\"artifact\",\"resource_id\":\"a\"}",
            "{\"lane\":\"terminal\",\"resource_id\":\"bad id!\"}",
        ]
        for preamble in bad {
            #expect(throws: BridgeLaneDescriptorError.invalidDescriptor) {
                _ = try BridgeLaneDescriptor.lane(fromPreamble: preamble)
            }
        }
    }
}

/// Live-QUIC bridged-session rig: two loopback endpoints, real admission,
/// then legacy-shaped lanes over raw streams in both directions.
@Suite("Bridged lanes over live QUIC", .serialized)
struct BridgeLaneLiveTests {
    struct Rig {
        let signer: GrantSigner
        let host: TransportHost
        let server: Endpoint
        let client: Endpoint
        let serverConn: IrohPeerConnection
        let clientConn: IrohPeerConnection
        let acceptor: BridgeLaneAcceptor

        static func admitAndBridge() async throws -> Rig {
            let signer = GrantSigner()
            let host = TransportHost(
                verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
            let mac = PeerIdentity.generate(appIdentity: "bridge.host", deviceID: "mac-1")
            let phone = PeerIdentity.generate(appIdentity: "bridge.ios", deviceID: "ph-1")
            let now = Int64(1_700_000_000)
            let grant = try signer.mint(
                accountID: "acct", deviceID: phone.deviceID,
                devicePublicKey: phone.publicKeyData, appIdentity: phone.appIdentity,
                grantID: "g-1", issuedAt: now)

            let server = try await IrohSubstrate.endpoint(identity: mac, minimalLoopback: true)
            let client = try await IrohSubstrate.endpoint(identity: phone, minimalLoopback: true)
            var clientConn: IrohPeerConnection?
            var serverConn: IrohPeerConnection?
            do {
                async let accepted = IrohSubstrate.acceptOne(endpoint: server)
                let connectedClient = try await IrohSubstrate.dial(
                    endpoint: client, to: IrohSubstrate.directAddr(of: server))
                clientConn = connectedClient
                guard let acceptedConnection = try await accepted else {
                    throw TransportError.pipeClosed
                }
                serverConn = acceptedConnection
                async let serving: Void = host.serve(
                    connection: acceptedConnection, now: now)
                let outcome = try await TransportClient.connect(
                    connection: connectedClient, identity: phone, grant: grant)
                guard case .admitted = outcome else { throw TransportError.pipeClosed }
                await serving
                guard await host.activeSession(for: acceptedConnection) != nil else {
                    throw TransportError.pipeClosed
                }

                let acceptor = await BridgeLaneAcceptor.attached(to: acceptedConnection)
                return Rig(
                    signer: signer, host: host, server: server, client: client,
                    serverConn: acceptedConnection, clientConn: connectedClient, acceptor: acceptor)
            } catch {
                await clientConn?.closeAll(reason: nil)
                await serverConn?.closeAll(reason: nil)
                try? await server.close()
                try? await client.close()
                throw error
            }
        }

        func tearDown() async {
            await clientConn.closeAll(reason: nil)
            await serverConn.closeAll(reason: nil)
            try? await server.close()
            try? await client.close()
        }
    }

    /// Owns a live QUIC rig for the duration of one test body and guarantees
    /// endpoint/connection teardown even when an assertion or decode throws.
    private func withRig<T>(
        _ body: (Rig) async throws -> T
    ) async throws -> T {
        let rig = try await Rig.admitAndBridge()
        do {
            let result = try await body(rig)
            await rig.tearDown()
            return result
        } catch {
            await rig.tearDown()
            throw error
        }
    }

    @Test("Terminal lane: descriptor, both directions, clean finish")
    func terminalLane() async throws {
        try await withRig { rig in
            let resourceID = try CmxIrohResourceID("terminal:abc123")

            let stream = try await BridgeLaneDialer.openLane(
                on: rig.clientConn,
                lane: .terminal(resourceID: resourceID, cursor: 9), priority: 10)
            let (lane, hostStream) = try await rig.acceptor.acceptBidirectionalLane()
            #expect(lane == .terminal(resourceID: resourceID, cursor: 9))

            try await stream.sendStream.send(Data("input-bytes".utf8))
            var got = Data()
            while got.count < 11,
                let chunk = try await hostStream.receiveStream.receive(maximumByteCount: 64)
            {
                got.append(chunk)
            }
            #expect(String(data: got, encoding: .utf8) == "input-bytes")

            try await hostStream.sendStream.send(Data("output-bytes".utf8))
            try await hostStream.sendStream.finish()
            var echoed = Data()
            while let chunk = try await stream.receiveStream.receive(maximumByteCount: 64) {
                echoed.append(chunk)
            }
            #expect(String(data: echoed, encoding: .utf8) == "output-bytes")
        }
    }

    @Test("Control transport: request and response bytes")
    func controlTransport() async throws {
        try await withRig { rig in
            let phoneControl = try await BridgeLaneDialer.openControlTransport(on: rig.clientConn)
            try await phoneControl.send(Data("rpc-request".utf8))
            let macRaw = try await rig.acceptor.nextControlStream()
            let macControl = BridgeByteTransport(stream: macRaw)
            var request = Data()
            while request.count < 11, let chunk = try await macControl.receive() {
                request.append(chunk)
            }
            #expect(String(data: request, encoding: .utf8) == "rpc-request")

            try await macControl.send(Data("rpc-response".utf8))
            var response = Data()
            while response.count < 12, let chunk = try await phoneControl.receive() {
                response.append(chunk)
            }
            #expect(String(data: response, encoding: .utf8) == "rpc-response")
        }
    }

    @Test("Bad preamble rejects that stream, session stays usable")
    func rejectionKeepsSession() async throws {
        try await withRig { rig in
            _ = try await rig.clientConn.openRawStream(preamble: "not a descriptor")
            await #expect(throws: CmxIrohServerSessionError.applicationLaneRejected) {
                _ = try await rig.acceptor.acceptBidirectionalLane()
            }

            let resourceID = try CmxIrohResourceID("terminal:after-reject")
            _ = try await BridgeLaneDialer.openLane(
                on: rig.clientConn,
                lane: .terminal(resourceID: resourceID, cursor: nil), priority: 0)
            let (lane, _) = try await rig.acceptor.acceptBidirectionalLane()
            #expect(lane == .terminal(resourceID: resourceID, cursor: nil))
        }
    }

    @Test("Peer-opened server events lane is rejected")
    func peerServerEventsRejected() async throws {
        try await withRig { rig in
            _ = try await rig.clientConn.openRawStream(
                preamble: BridgeLaneDescriptor.preamble(for: .serverEvents(cursor: nil)))
            await #expect(throws: CmxIrohServerSessionError.applicationLaneRejected) {
                _ = try await rig.acceptor.acceptBidirectionalLane()
            }
        }
    }

    @Test("Host-opened server events arrive at the peer")
    func hostServerEvents() async throws {
        try await withRig { rig in
            let phoneAcceptor = await BridgeLaneAcceptor.attached(
                to: rig.clientConn, acceptsServerEvents: true)
            let sender = try await BridgeLaneDialer.openServerEventSendStream(
                on: rig.serverConn, priority: 50)
            try await sender.send(Data("event-1".utf8))
            try await sender.finish()

            // The phone treats host-opened server events like the Mac treats a
            // control stream: pulled explicitly, not via the app-lane accept.
            let (lane, stream) = try await phoneAcceptor.acceptServerEventStream()
            #expect(lane == .serverEvents(cursor: nil))
            var got = Data()
            while let chunk = try await stream.receiveStream.receive(maximumByteCount: 64) {
                got.append(chunk)
            }
            #expect(String(data: got, encoding: .utf8) == "event-1")
        }
    }

    @Test("Application-lane opener rejects reserved lane kinds")
    func applicationOpenerRejectsReservedKinds() async throws {
        try await withRig { rig in
            for lane in [CmxIrohLane.control, .serverEvents(cursor: nil)] {
                await #expect(throws: CmxIrohClientSessionError.invalidOutgoingLane) {
                    _ = try await BridgeLaneDialer.openLane(
                        on: rig.clientConn, lane: lane, priority: 0)
                }
            }
        }
    }

    @Test("Closed bridge byte transport rejects every later operation")
    func closedByteTransportRejectsUse() async throws {
        try await withRig { rig in
            let phoneControl = try await BridgeLaneDialer.openControlTransport(on: rig.clientConn)
            _ = try await rig.acceptor.nextControlStream()
            await phoneControl.close()

            await #expect(throws: CmxIrohByteTransportError.alreadyClosed) {
                try await phoneControl.connect()
            }
            await #expect(throws: CmxIrohByteTransportError.alreadyClosed) {
                _ = try await phoneControl.receive()
            }
            await #expect(throws: CmxIrohByteTransportError.alreadyClosed) {
                try await phoneControl.send(Data("after-close".utf8))
            }
        }
    }

    @Test("Connection close ends the accept loop")
    func closeEndsAccept() async throws {
        try await withRig { rig in
            await rig.clientConn.closeAll(reason: nil)
            await #expect(throws: BridgeAcceptError.connectionClosed) {
                while true {
                    _ = try await rig.acceptor.acceptBidirectionalLane()
                }
            }
        }
    }
}
