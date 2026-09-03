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

    @Test("Decoder exposes exact bytes for a framed-to-raw handoff")
    func preservesEncodedFrameBytes() throws {
        // Deliberately use a JSON key order/whitespace that a new encoder would
        // not necessarily reproduce.
        let body = Data(#"{ "p": { "b": 2, "a": 1 }, "t": "raw.open", "v": 1 }"#.utf8)
        var wire = Data()
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { wire.append(contentsOf: $0) }
        wire.append(body)

        var decoder = FrameDecoder(captureEncodedFrames: true)
        _ = try decoder.feed(wire)
        #expect(decoder.drainEncodedFrames() == [wire])
    }

    @Test("Opening-frame decode preserves coalesced raw bytes verbatim")
    func openingFrameLeavesRawRemainder() throws {
        let opening = Frame(type: "raw.open", payload: ["preamble": .string("ctl")])
        let encodedOpening = try FrameEncoder().encode(opening)
        let rawBytes = Data([0x00, 0x01, 0x02, 0xFF, 0x7F])
        var decoder = FrameDecoder(captureEncodedFrames: true)
        var coalesced = encodedOpening
        coalesced.append(rawBytes)

        let decodedOptional = try decoder.feedFirst(coalesced)
        let decoded = try #require(decodedOptional)
        #expect(decoded == opening)
        #expect(decoder.drainRemainder() == rawBytes)
        // The opening frame remains available for diagnostics, but it is not
        // part of the raw handoff remainder.
        #expect(decoder.drainEncodedFrames() == [encodedOpening])
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
        #expect(policy.classify(FrameTypes.grantExpiring) == .known)
        #expect(policy.classify(FrameTypes.relayCredential) == .known)
        #expect(policy.classify(FrameTypes.chatTyping) == .known)
        #expect(policy.classify("opt.telemetry") == .ignorableUnknown)
        #expect(policy.classify("ctl.future-feature") == .fatalUnknown)
    }

    @Test("A terminal sequence number is malformed instead of overflowing")
    func terminalSequenceDoesNotTrap() {
        var validator = TrafficValidator()
        validator.ingest(Frame.dataChunk(seq: Int64.max, data: Data([0x01])))
        #expect(validator.malformedFrames == 1)
        #expect(validator.expectedSeq == 0)
        #expect(!validator.isClean)
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
