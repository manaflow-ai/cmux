import Foundation
import Testing

@testable import CmuxNextTransport

@Suite("Framing (contract 6.x)")
struct FramingTests {
    @Test("Round-trips every JSON value kind")
    func roundTrip() throws {
        let frame = Frame(
            type: "ctl.hello",
            payload: [
                "string": .string("value"),
                "int": .int(9_007_199_254_740_993),  // > 2^53, must survive
                "double": .double(1.5),
                "bool": .bool(true),
                "null": .null,
                "array": .array([.int(1), .string("two")]),
                "object": .object(["nested": .bool(false)]),
                "data": .data(Data([0x00, 0xFF, 0x10])),
            ])
        var decoder = FrameDecoder()
        let frames = try decoder.feed(try FrameEncoder().encode(frame))
        #expect(frames == [frame])
        #expect(frames[0].payload["data"]?.dataValue == Data([0x00, 0xFF, 0x10]))
        #expect(frames[0].payload["int"]?.intValue == 9_007_199_254_740_993)
    }

    @Test("Reassembles frames fed one byte at a time")
    func chunkedFeed() throws {
        let encoder = FrameEncoder()
        let first = Frame(type: "data.chunk", payload: ["seq": .int(1)])
        let second = Frame(type: "data.chunk", payload: ["seq": .int(2)])
        var wire = Data()
        wire.append(try encoder.encode(first))
        wire.append(try encoder.encode(second))

        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        for byte in wire {
            decoded.append(contentsOf: try decoder.feed(Data([byte])))
        }
        #expect(decoded == [first, second])
    }

    @Test("Rejects oversize frames before buffering them")
    func oversizeRejected() throws {
        var decoder = FrameDecoder()
        var prefix = Data()
        let huge = UInt32(CmuxPeerProtocol.maxFrameLength + 1).bigEndian
        withUnsafeBytes(of: huge) { prefix.append(contentsOf: $0) }
        #expect(throws: FrameCodecError.frameTooLarge(length: CmuxPeerProtocol.maxFrameLength + 1)) {
            try decoder.feed(prefix)
        }
    }

    @Test("Rejects malformed JSON with a typed error")
    func malformedJSON() throws {
        var decoder = FrameDecoder()
        let garbage = Data("not json!!".utf8)
        var wire = Data()
        let length = UInt32(garbage.count).bigEndian
        withUnsafeBytes(of: length) { wire.append(contentsOf: $0) }
        wire.append(garbage)
        #expect(throws: FrameCodecError.malformedJSON) {
            try decoder.feed(wire)
        }
    }

    @Test("Rejects an unsupported envelope version explicitly (6.3)")
    func unsupportedVersion() throws {
        var decoder = FrameDecoder()
        let body = Data(#"{"v":2,"t":"ctl.hello","p":{}}"#.utf8)
        var wire = Data()
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { wire.append(contentsOf: $0) }
        wire.append(body)
        #expect(throws: FrameCodecError.unsupportedVersion(2)) {
            try decoder.feed(wire)
        }
    }

    @Test("Unknown types: opt.* is ignorable, everything else is fatal (6.3)")
    func typePolicy() {
        let policy = FrameTypePolicy()
        #expect(policy.classify(FrameTypes.hello) == .known)
        #expect(policy.classify("opt.telemetry") == .ignorableUnknown)
        #expect(policy.classify("ctl.future-feature") == .fatalUnknown)
    }
}

extension FramingTests {
    @Test("Fast hex matches the reference encoding and the wire digest")
    func hexEncoding() {
        #expect(HexEncoding.lowercase([]) == "")
        #expect(HexEncoding.lowercase(Data([0x00, 0x0F, 0xAB, 0xFF])) == "000fabff")
        let bytes = (UInt8.min...UInt8.max).map { $0 }
        let reference = bytes.map { String(format: "%02x", $0) }.joined()
        #expect(HexEncoding.lowercase(bytes) == reference)

        // The digest a sender mints must still satisfy the receiving
        // validator (same helper on both hot paths).
        var validator = TrafficValidator()
        validator.ingest(Frame.dataChunk(seq: 0, data: Data(bytes)))
        #expect(validator.isClean)
        #expect(validator.received == 1)
    }
}
