import Foundation
import Testing
@testable import CmuxAttach

@Suite struct AttachFrameTests {
    private func roundTrip(_ frame: AttachFrame) throws -> AttachFrame {
        try AttachFrame(line: frame.encodedLine())
    }

    @Test func attachRoundTrips() throws {
        let frame = AttachFrame.attach(
            AttachRequest(surface: "surface:2", size: SurfaceSize(cols: 90, rows: 30), readOnly: true)
        )
        #expect(try roundTrip(frame) == frame)
    }

    @Test func ackRoundTrips() throws {
        let frame = AttachFrame.ack(seq: 4096)
        #expect(try roundTrip(frame) == frame)
    }

    @Test func resizeRoundTrips() throws {
        let frame = AttachFrame.resize(cols: 100, rows: 50)
        #expect(try roundTrip(frame) == frame)
    }

    @Test func detachAndHeartbeatRoundTrip() throws {
        #expect(try roundTrip(.detach) == .detach)
        #expect(try roundTrip(.heartbeat) == .heartbeat)
    }

    @Test func errorRoundTrips() throws {
        let frame = AttachFrame.error(code: "surface_not_found", message: "no such surface")
        #expect(try roundTrip(frame) == frame)
    }

    @Test func outputPreservesArbitraryBinaryBytes() throws {
        // Every byte value 0...255, including NUL, newline, and high bytes.
        let bytes = Data((0...255).map { UInt8($0) })
        let frame = AttachFrame.output(seq: 7, bytes: bytes)
        let decoded = try roundTrip(frame)
        #expect(decoded == .output(seq: 7, bytes: bytes))
    }

    @Test func inputPreservesControlBytes() throws {
        let bytes = Data([0x03, 0x1B, 0x5B, 0x41]) // Ctrl-C then ESC [ A (up arrow)
        let frame = AttachFrame.input(bytes: bytes)
        #expect(try roundTrip(frame) == frame)
    }

    @Test func encodedLineEndsWithNewlineAndHasNoInteriorNewline() {
        let line = AttachFrame.output(seq: 1, bytes: Data("hello\nworld".utf8)).encodedLine()
        #expect(line.last == 0x0A)
        // The payload newline is base64-encoded, so the only newline is the terminator.
        #expect(line.dropLast().firstIndex(of: 0x0A) == nil)
    }

    @Test func decodeToleratesMissingTrailingNewline() throws {
        var line = AttachFrame.ack(seq: 1).encodedLine()
        if line.last == 0x0A { line.removeLast() }
        #expect(try AttachFrame(line: line) == .ack(seq: 1))
    }

    @Test func emptyLineIsMalformed() {
        #expect(throws: AttachFrameError.malformed) {
            try AttachFrame(line: Data())
        }
    }

    @Test func nonJsonLineIsMalformed() {
        #expect(throws: AttachFrameError.malformed) {
            try AttachFrame(line: Data("not json".utf8))
        }
    }

    @Test func missingTypeTagThrows() {
        #expect(throws: AttachFrameError.missingField("t")) {
            try AttachFrame(line: Data(#"{"seq":1}"#.utf8))
        }
    }

    @Test func unknownTypeThrows() {
        #expect(throws: AttachFrameError.unknownType("bogus")) {
            try AttachFrame(line: Data(#"{"t":"bogus"}"#.utf8))
        }
    }

    @Test func invalidBase64PayloadThrows() {
        #expect(throws: AttachFrameError.invalidPayload) {
            try AttachFrame(line: Data(#"{"t":"in","b64":"!!!not-base64!!!"}"#.utf8))
        }
    }

    @Test func outputAcceptsNumericStringSeq() throws {
        let decoded = try AttachFrame(line: Data(#"{"t":"out","seq":"42","b64":""}"#.utf8))
        #expect(decoded == .output(seq: 42, bytes: Data()))
    }

    @Test func negativeSeqIsRejected() {
        // seq is a UInt64 byte offset; a negative value must not wrap or coerce.
        #expect(throws: AttachFrameError.self) {
            try AttachFrame(line: Data(#"{"t":"out","seq":-1,"b64":""}"#.utf8))
        }
    }

    @Test func oversizePayloadIsRejected() {
        // A base64 string whose decoded size exceeds the per-frame cap must be
        // rejected before allocating, not decoded.
        let oversize = String(repeating: "A", count: AttachFrame.maxPayloadBytes / 3 * 4 + 16)
        let line = Data(#"{"t":"in","b64":"\#(oversize)"}"#.utf8)
        #expect(throws: AttachFrameError.invalidPayload) {
            try AttachFrame(line: line)
        }
    }

    @Test func maxSizePayloadIsAccepted() throws {
        // A payload at the cap still round-trips.
        let bytes = Data(repeating: 0x41, count: 1024)
        let frame = AttachFrame.input(bytes: bytes)
        #expect(try AttachFrame(line: frame.encodedLine()) == frame)
    }
}
