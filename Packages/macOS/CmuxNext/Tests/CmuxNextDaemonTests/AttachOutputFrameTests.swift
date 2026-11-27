import Foundation
import Testing
@testable import CmuxNextDaemon

/// `attach-frames-v1` (terminal-throughput G5): the daemon sends plain `output` as binary OUTPUT frames, and
/// the reader takes the PTY bytes as they are, with no JSON scan and no base64 decode.
@Suite struct AttachOutputFrameTests {
    private func split(_ chunks: [Data]) -> (lines: [Data], frames: [Data], splitter: LineSplitter) {
        var splitter = LineSplitter()
        var lines: [Data] = []
        var frames: [Data] = []
        for chunk in chunks { splitter.append(chunk, line: { lines.append($0) }, frame: { frames.append($0) }) }
        return (lines, frames, splitter)
    }

    @Test func aFrameRoundTripsItsHeaderAndPayload() throws {
        let payload = Data((0..<1000).map { UInt8($0 % 256) })
        let frame = AttachOutputFrame(stream: 3, offset: 1 << 40, payload: payload)
        let wire = frame.encoded
        #expect(wire.count == 16 + payload.count)
        #expect(wire[0] == 0xFF && wire[1] == 1)
        #expect(AttachOutputFrame(message: wire) == frame)
        // A short or overlong message and another kind are refused.
        #expect(AttachOutputFrame(message: wire.dropLast()) == nil)
        var other = wire
        other[1] = 2
        #expect(AttachOutputFrame(message: other) == nil)
    }

    @Test func framesWithNewlinesSitBetweenLinesInWireOrder() throws {
        let payload = Data("one\ntwo\n\u{1b}[0m\n".utf8) + Data([0xFF, 0x0A, 0x00])
        let frame = AttachOutputFrame(offset: 10, payload: payload).encoded
        let stream = Data(#"{"event":"snapshot"}"#.utf8) + Data([0x0A]) + frame + frame
            + Data(#"{"event":"size-state"}"#.utf8) + Data([0x0A])
        let whole = split([stream])
        #expect(whole.lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"event":"snapshot"}"#, #"{"event":"size-state"}"#])
        #expect(whole.frames == [frame, frame])
        #expect(whole.splitter.pending.isEmpty)
        // The same stream one byte per read: a frame cut anywhere (in its header too) waits for the rest.
        let bytewise = split(stream.map { Data([$0]) })
        #expect(bytewise.lines == whole.lines)
        #expect(bytewise.frames == whole.frames)
        #expect(bytewise.splitter.pending.isEmpty)
    }

    @Test func eachLineByteIsSearchedOnce() {
        // A 1 MB line in 1 KB reads: linear, as before frames.
        let line = Data(repeating: UInt8(ascii: "a"), count: 1 << 20) + Data([0x0A])
        let chunks = stride(from: 0, to: line.count, by: 1024).map { line[$0..<min($0 + 1024, line.count)] }.map { Data($0) }
        let result = split(chunks)
        #expect(result.lines.count == 1)
        #expect(result.splitter.scannedBytes == line.count)
    }

    @Test func aFrameDecodesToItsRawOutput() throws {
        let payload = Data("hello\r\n".utf8)
        let decoded = try #require(TerminalAttachment.decodeAttachLine(
            name: LineTransport.outputFrameEvent, line: AttachOutputFrame(offset: 42, payload: payload).encoded,
            surface: SurfaceID(rawValue: 1)))
        #expect(decoded.event == .output(payload, colors: nil))
        #expect(decoded.frameOffset == 42)
        #expect(TerminalAttachment.decodeAttachLine(name: LineTransport.outputFrameEvent, line: Data([0xFF, 1]),
                                                    surface: SurfaceID(rawValue: 1)) == nil)
    }

    @Test func aFrameKeepsOnlyItsBytesFromTheReadyCut() {
        var sequencer = TerminalSnapshotSequencer()
        func frame(_ offset: UInt64, _ text: String) -> TerminalChannelEvent? {
            sequencer.admit(DecodedAttachLine(event: .output(Data(text.utf8), colors: nil), frameOffset: offset))
        }
        // No READY yet (a byte attach): every frame passes.
        #expect(frame(0, "abc") == .output(Data("abc".utf8), colors: nil))
        let ready = TerminalSnapshotFrame(phase: .ready, generation: 2, offset: 100, version: 1, cols: 80, rows: 24, data: Data())
        _ = sequencer.admit(DecodedAttachLine(event: .snapshot(ready)))
        #expect(frame(90, "0123456789") == nil)
        #expect(frame(95, "0123456789") == .output(Data("56789".utf8), colors: nil))
        #expect(frame(100, "xyz") == .output(Data("xyz".utf8), colors: nil))
    }
}
