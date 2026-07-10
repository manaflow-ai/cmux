import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohAdmissionAckCodecTests {
    @Test(arguments: [
        CmxIrohAdmissionDecision.accepted,
        CmxIrohAdmissionDecision.denied(code: 1),
        CmxIrohAdmissionDecision.denied(code: .max),
    ])
    func decisionRoundTripsInEightBytes(_ decision: CmxIrohAdmissionDecision) throws {
        let codec = CmxIrohAdmissionAckCodec()
        let encoded = codec.encode(decision)

        #expect(encoded.count == CmxIrohAdmissionAckCodec.frameByteCount)
        #expect(try codec.decodePrefix(encoded + Data([0xff])) == decision)
    }

    @Test
    func malformedDecisionFailsClosed() throws {
        let codec = CmxIrohAdmissionAckCodec()
        #expect(throws: CmxIrohAdmissionAckCodecError.incompleteFrame) {
            try codec.decodePrefix(Data(repeating: 0, count: 7))
        }

        var invalidMagic = codec.encode(.accepted)
        invalidMagic[0] = 0
        #expect(throws: CmxIrohAdmissionAckCodecError.invalidMagic) {
            try codec.decodePrefix(invalidMagic)
        }

        var invalidVersion = codec.encode(.accepted)
        invalidVersion[4] = 2
        #expect(throws: CmxIrohAdmissionAckCodecError.unsupportedVersion(2)) {
            try codec.decodePrefix(invalidVersion)
        }

        var invalidStatus = codec.encode(.accepted)
        invalidStatus[5] = 2
        #expect(throws: CmxIrohAdmissionAckCodecError.invalidStatus(2)) {
            try codec.decodePrefix(invalidStatus)
        }

        var invalidAcceptedCode = codec.encode(.accepted)
        invalidAcceptedCode[7] = 1
        #expect(throws: CmxIrohAdmissionAckCodecError.invalidAcceptedCode(1)) {
            try codec.decodePrefix(invalidAcceptedCode)
        }
    }
}
