import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Input acknowledgement envelope")
struct CmxIrohInputAcknowledgementEnvelopeTests {
    @Test func acknowledgementSurvivesTheLaneCodecBetweenOutputFrames() throws {
        let ack = MobileTerminalInputAcknowledgement(status: .applied, streamID: UUID(), sequence: 12)
        let codec = CmxIrohTerminalOutputEnvelopeCodec()
        let output = try CmxIrohTerminalOutputEnvelope(
            kind: .chunk, retainedBaseSequence: 0, sequence: 3, currentSequence: 5, payload: Data("hi".utf8)
        )
        var bytes = codec.encode(output)
        bytes.append(codec.encode(.inputAcknowledgement(ack)))
        var decoder = CmxIrohTerminalOutputEnvelopeDecoder()
        let envelopes = try decoder.append(bytes)
        #expect(envelopes.count == 2)
        #expect(envelopes[0].inputAcknowledgement == nil)
        #expect(envelopes[1].kind == .inputAcknowledgement)
        #expect(envelopes[1].inputAcknowledgement == ack)
    }
}
