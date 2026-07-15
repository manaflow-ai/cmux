import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

struct ServerFixture {
    let peerID: CmxIrohPeerIdentity
    let admittedPeer: CmxIrohAdmittedPeer
    let authorizer: FixedAdmissionAuthorizer
    let headerCodec = try! CmxIrohStreamHeaderCodec()
    let controlSend: TestIrohSendStream
    let controlStream: CmxIrohBidirectionalStream

    init(
        decision: CmxIrohAdmissionDecision,
        clientReadyFrame: Data? = admissionFrame(status: 2),
        applicationBytes: Data = Data("rpc".utf8),
        eventRecorder: TestIrohEventRecorder? = nil
    ) throws {
        let peerID = try CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64))
        let admittedPeer = CmxIrohAdmittedPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            endpointID: peerID,
            identityGeneration: 7,
            platform: .ios
        )
        self.peerID = peerID
        self.admittedPeer = admittedPeer
        let authorization: CmxIrohAdmissionAuthorization = switch decision {
        case .accepted:
            .accepted(admittedPeer, onlineLease: nil)
        case let .denied(code):
            .denied(code: code)
        }
        authorizer = FixedAdmissionAuthorizer(authorization: authorization)
        controlSend = TestIrohSendStream(
            eventRecorder: eventRecorder,
            eventName: "control.send"
        )
        let credential = try CmxIrohAdmissionCredential.pairGrant("aa.bb.cc")
        let header = try headerCodec.encode(
            CmxIrohStreamHeader(lane: .control, credential: credential)
        )
        let readyFrame = if decision == .accepted {
            clientReadyFrame ?? Data()
        } else {
            Data()
        }
        controlStream = CmxIrohBidirectionalStream(
            receiveStream: TestIrohReceiveStream(
                buffer: header + readyFrame + applicationBytes
            ),
            sendStream: controlSend
        )
    }
}

func admissionFrame(status: UInt8, code: UInt16 = 0) -> Data {
    var frame = Data("CMXA".utf8)
    frame.append(1)
    frame.append(status)
    let bigEndian = code.bigEndian
    withUnsafeBytes(of: bigEndian) { frame.append(contentsOf: $0) }
    return frame
}
