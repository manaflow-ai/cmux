import Foundation
import Testing

@testable import CmuxPeerTransport

@Suite struct PtxFrameTests {
    @Test func roundTripAcrossSplitReads() throws {
        let encoder = PtxFrameEncoder()
        var decoder = PtxFrameDecoder()
        let frames = [
            PtxFrame(type: "ctl.hello", payload: ["a": .int(1)]),
            PtxFrame(type: "raw.open", payload: ["d": .string("x")]),
        ]
        var wire = Data()
        for frame in frames { wire.append(try encoder.encode(frame)) }
        var decoded: [PtxFrame] = []
        for byte in wire {
            decoder.feed(Data([byte]))
            while let frame = try decoder.next() { decoded.append(frame) }
        }
        #expect(decoded == frames)
    }

    /// Raw bytes after the handshake frame must survive verbatim, even when
    /// they look like a bogus giant length prefix ("rawb" ≈ 1.9 GB): the
    /// decoder never parses past the frame it returned.
    @Test func remainderAfterHandshakeIsUntouched() throws {
        var decoder = PtxFrameDecoder()
        let frame = PtxFrame(type: "raw.open")
        var wire = try PtxFrameEncoder().encode(frame)
        let tail = Data("rawbytes-after-handshake".utf8)
        wire.append(tail)
        decoder.feed(wire)
        #expect(try decoder.next() == frame)
        #expect(decoder.drainRemainder() == tail)
    }

    /// Same, with a tail that parses as a plausible frame: it must come back
    /// byte-identical, not re-encoded.
    @Test func frameShapedRemainderStaysByteIdentical() throws {
        var decoder = PtxFrameDecoder()
        let handshake = try PtxFrameEncoder().encode(PtxFrame(type: "raw.open"))
        // A hand-crafted envelope with unusual key order and spacing that a
        // decode/re-encode cycle would not reproduce.
        let body = Data("{\"t\":\"x\",\"p\":{\"z\":1,\"a\":2},\"v\":1}".utf8)
        var tail = Data()
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { tail.append(contentsOf: $0) }
        tail.append(body)
        var wire = handshake
        wire.append(tail)
        decoder.feed(wire)
        _ = try decoder.next()
        #expect(decoder.drainRemainder() == tail)
    }

    @Test func oversizeHeadFrameIsAProtocolError() {
        var decoder = PtxFrameDecoder()
        decoder.feed(Data("XXXXtrailing".utf8))
        #expect(throws: PtxFrameError.self) {
            _ = try decoder.next()
        }
    }
}
