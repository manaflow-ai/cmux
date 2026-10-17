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
            params: .object(["payload": .string(String(repeating: "x", count: PhoneProtocol.maxRequestLineBytes))])
        )
        #expect(throws: PhoneWireCodecError.lineTooLarge) {
            try codec.encode(oversized)
        }

        let screenshotResponse = PhoneEnvelope.response(
            id: "frame",
            result: .object(["data": .string(String(repeating: "x", count: 100_000))])
        )
        #expect(try codec.encode(screenshotResponse).count > 100_000)

        var requestDecoder = PhoneLineDecoder(maxLineBytes: PhoneProtocol.maxRequestLineBytes)
        let oversizedRequest = Data(
            ("{\"protocol\":\"cmux.phone\",\"version\":1,\"type\":\"request\",\"id\":\"large\",\"method\":\"device.list\",\"params\":{\"x\":\""
             + String(repeating: "x", count: PhoneProtocol.maxRequestLineBytes)
             + "\"}}\n").utf8
        )
        #expect(throws: PhoneWireCodecError.lineTooLarge) {
            _ = try requestDecoder.append(oversizedRequest)
        }
    }

    @Test
    func unknownEnvelopeAndErrorFieldsAreRejected() throws {
        let codec = PhoneWireCodec()
        let unknownEnvelope = Data("{\"protocol\":\"cmux.phone\",\"version\":1,\"type\":\"request\",\"id\":\"1\",\"method\":\"device.list\",\"extra\":true}\n".utf8)
        #expect(throws: PhoneWireCodecError.invalidJSON) {
            try codec.decode(unknownEnvelope)
        }
        let unknownError = Data("{\"protocol\":\"cmux.phone\",\"version\":1,\"type\":\"error\",\"error\":{\"code\":\"x\",\"message\":\"m\",\"retryable\":false,\"extra\":true}}\n".utf8)
        #expect(throws: PhoneWireCodecError.invalidJSON) {
            try codec.decode(unknownError)
        }
    }

    @Test
    func defaultDecodeLimitIsTheRequestLimit() throws {
        let codec = PhoneWireCodec()
        let response = PhoneEnvelope.response(
            id: "frame",
            result: .object(["data": .string(String(repeating: "x", count: PhoneProtocol.maxRequestLineBytes))])
        )
        let encoded = try PhoneWireCodec().encode(response)
        #expect(throws: PhoneWireCodecError.lineTooLarge) {
            try codec.decode(encoded)
        }
        #expect(try codec.decode(encoded, maxLineBytes: PhoneProtocol.maxResponseLineBytes) == response)
    }

    @Test
    func malformedProtocolIsRejected() throws {
        let codec = PhoneWireCodec()
        let data = Data("{\"protocol\":\"other\",\"version\":1,\"type\":\"request\"}\n".utf8)
        #expect(throws: PhoneWireCodecError.invalidProtocol) {
            try codec.decode(data)
        }
    }

    @Test
    func envelopeRequiredFieldsAreRejected() throws {
        let codec = PhoneWireCodec()
        let invalidEnvelopes = [
            PhoneEnvelope(type: .request, method: "device.list"),
            PhoneEnvelope(type: .response),
            PhoneEnvelope(type: .event, method: "ui.changed"),
            PhoneEnvelope(type: .error),
        ]

        for envelope in invalidEnvelopes {
            let encoded = try JSONEncoder().encode(envelope) + Data([0x0A])
            #expect(throws: PhoneWireCodecError.invalidMessageType) {
                try codec.decode(encoded)
            }
        }
    }
}
