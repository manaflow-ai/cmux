import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Wire-level contract for allowlist admission: an already-paired phone opens
/// its control stream with NO admission credential, and the header remains
/// representable and round-trippable in that credential-less form.
@Suite
struct CmxIrohPairedPeerWireTests {
    @Test
    func controlHeaderWithoutCredentialIsValid() throws {
        let header = try CmxIrohStreamHeader(lane: .control, credential: nil)
        #expect(header.credential == nil)
        #expect(header.lane == .control)
    }

    @Test
    func codecRoundTripsCredentiallessControlHeader() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let encoded = try codec.encode(
            try CmxIrohStreamHeader(lane: .control, credential: nil)
        )
        let decoded = try codec.decodePrefix(encoded)
        #expect(decoded.header.lane == .control)
        #expect(decoded.header.credential == nil)
        #expect(decoded.consumedByteCount == encoded.count)
    }

    @Test
    func codecDecodesCredentialCodeZeroControlFrame() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        var frame = Data("CMUXIRH1".utf8)
        frame.append(1) // version
        frame.append(1) // lane: control
        frame.append(0) // flags
        frame.append(0) // credential code: none (allowlist admission)
        frame.append(contentsOf: [0, 0, 0, 0] as [UInt8]) // payload byte count
        let decoded = try codec.decodePrefix(frame)
        #expect(decoded.header.lane == .control)
        #expect(decoded.header.credential == nil)
    }

    /// End-to-end server admission of a credential-less control stream: the
    /// authorizer sees credential nil bound to the TLS-proven identity, and
    /// the ordinary admission barrier (accept frame, clientReady, serverReady)
    /// still runs.
    @Test
    func serverAdmitsCredentiallessControlStreamThroughAuthorizer() async throws {
        let peerID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let admittedPeer = CmxIrohAdmittedPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            endpointID: peerID,
            identityGeneration: 7,
            platform: .ios
        )
        let authorizer = CredentialRecordingAuthorizer(
            authorization: .accepted(admittedPeer, onlineLease: nil)
        )
        let codec = try CmxIrohStreamHeaderCodec()
        let header = try codec.encode(
            CmxIrohStreamHeader(lane: .control, credential: nil)
        )
        let controlStream = CmxIrohBidirectionalStream(
            receiveStream: TestIrohReceiveStream(
                buffer: header + admissionFrame(status: 2)
            ),
            sendStream: TestIrohSendStream(
                eventRecorder: nil,
                eventName: "control.send"
            )
        )
        let connection = TestIrohConnection(
            remoteIdentity: peerID,
            bidirectionalStreams: [controlStream]
        )
        let server = try CmxIrohServerSession(
            connection: connection,
            authorizer: authorizer
        )
        let peer = try await server.admit()
        #expect(peer == admittedPeer)
        let observed = await authorizer.observedCredentials()
        #expect(observed == [nil])
    }
}
