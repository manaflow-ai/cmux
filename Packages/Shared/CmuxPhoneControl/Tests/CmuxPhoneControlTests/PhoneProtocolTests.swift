import Foundation
import Testing

@testable import CmuxPhoneControl

@Suite("cmux.phone protocol")
struct PhoneProtocolTests {
    @Test
    func envelopesRoundTripWithTaggedJSON() throws {
        let envelope = PhoneEnvelope.request(
            id: "request-1",
            method: "action.tap",
            sessionID: "session-1",
            params: .object([
                "action_id": .string("tap-1"),
                "point": .object(["x": .number(0.25), "y": .number(0.75)]),
            ])
        )
        let codec = PhoneWireCodec()
        let encoded = try codec.encode(envelope)
        #expect(encoded.last == 0x0A)
        #expect(try codec.decode(encoded) == envelope)
    }

    @Test
    func lineDecoderHandlesMultipleMessagesAndArbitraryChunks() throws {
        let codec = PhoneWireCodec()
        let first = try codec.encode(.request(id: "1", method: "device.list"))
        let second = try codec.encode(.request(id: "2", method: "session.open"))
        var decoder = PhoneLineDecoder()
        var output: [PhoneEnvelope] = []
        for byte in (first + second) {
            output.append(contentsOf: try decoder.append(Data([byte])))
        }
        #expect(output.map(\.id) == ["1", "2"])
    }

    @Test
    func invalidVersionAndOversizeLinesAreRejected() throws {
        let codec = PhoneWireCodec()
        let unsupported = PhoneEnvelope(
            type: .request,
            id: "bad",
            method: "device.list",
            version: 99
        )
        #expect(throws: PhoneWireCodecError.unsupportedVersion(99)) {
            try codec.decode(try JSONEncoder().encode(unsupported) + Data([0x0A]))
        }
        let oversized = PhoneEnvelope(
            type: .request,
            id: "large",
            method: "device.list",
            params: .object(["payload": .string(String(repeating: "x", count: 70_000))])
        )
        #expect(throws: PhoneWireCodecError.lineTooLarge) {
            try codec.encode(oversized)
        }
    }

    @Test
    func malformedProtocolIsRejected() throws {
        let codec = PhoneWireCodec()
        let data = Data("{\"protocol\":\"other\",\"version\":1,\"type\":\"request\"}\n".utf8)
        #expect(throws: PhoneWireCodecError.invalidProtocol) {
            try codec.decode(data)
        }
    }
}
