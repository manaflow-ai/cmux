import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The multi-stream session core (rd change C6) and the stream splitter the
/// transport uses to open a popup stream before its first datagram.
struct RemoteRdSessionTests {
    private static func framed(_ au: [UInt8], stream: UInt16, frame: UInt32 = 1) throws -> Data {
        var out = Data()
        for d in RemoteRdCoreTests.datagrams(frame: frame, keyframe: true, accessUnit: au, tCapture: 3, shardLen: 64, firstSeq: 0, stream: stream) {
            out += try RemoteRdCore.streamFrame(d, control: false)
        }
        return out
    }

    @Test func eachStreamReassemblesItsOwnFramesOnceOpen() throws {
        let session = try #require(RemoteRdSession(carrier: .stream))
        let popup = RemoteRdCoreTests.annexB(0x65, 150)
        let page = RemoteRdCoreTests.annexB(0x65, 210)
        // Stream 1 is not open yet: its datagrams are skipped, the page's arrive.
        try session.push(streamBytes: try Self.framed(popup, stream: 1) + Self.framed(page, stream: 0), nowMicros: 1)
        let first = try #require(try session.popAccessUnit(codec: .h264))
        #expect(first.stream == 0)
        #expect([UInt8](first.unit.data) == page)
        #expect(try session.popAccessUnit(codec: .h264) == nil)

        try session.openStream(1)
        try session.push(streamBytes: try Self.framed(popup, stream: 1), nowMicros: 2)
        let second = try #require(try session.popAccessUnit(codec: .h264))
        #expect(second.stream == 1)
        #expect([UInt8](second.unit.data) == popup)

        try session.closeStream(1)
        #expect(throws: RemoteRdCoreError.stream) { try session.closeStream(1) }
        #expect(throws: RemoteRdCoreError.stream) { try session.requestKeyframe(stream: 1) }
        try session.requestKeyframe(stream: 0)
        #expect(try session.stats(stream: 0).framesReleased == 1)
    }

    @Test func controlMessagesComeOutInOrder() throws {
        let session = try #require(RemoteRdSession(carrier: .stream))
        let control = Data(#"{"t":"started","session":2}"#.utf8)
        try session.push(streamBytes: try RemoteRdCore.streamFrame(control, control: true), nowMicros: 1)
        #expect(try session.popMessage() == .control(control))
        #expect(try session.popMessage() == nil)
    }

    @Test func theSplitterCutsAfterEveryControlFrameAcrossReads() throws {
        let control = try RemoteRdCore.streamFrame(Data(#"{"t":"x"}"#.utf8), control: true)
        let datagram = try RemoteRdCore.streamFrame(Data([1, 2, 3, 4]), control: false)
        let stream = datagram + control + datagram + control
        var splitter = RemoteRdStreamSplitter()
        // Byte by byte: every cut still lands right after a control frame.
        var segments: [RemoteRdStreamSplitter.Segment] = []
        for byte in stream { segments += splitter.split(Data([byte])) }
        #expect(Data(segments.flatMap(\.bytes)) == stream)
        var cuts: [Int] = []
        var offset = 0
        for segment in segments {
            offset += segment.bytes.count
            if segment.endsControlFrame { cuts.append(offset) }
        }
        #expect(cuts == [datagram.count + control.count, stream.count])

        var whole = RemoteRdStreamSplitter()
        let pieces = whole.split(stream)
        #expect(pieces.map(\.endsControlFrame) == [true, true])
        #expect(pieces.map(\.bytes.count) == [datagram.count + control.count, datagram.count + control.count])
    }

    @Test func surfaceStreamChangesComeFromShowAndHideOnly() {
        #expect(RemoteRdSurfaceStreamChange(.object(["t": .string("rb.surface.show"), "surface": .int(4), "stream": .int(2)])) == .show(surface: 4, stream: 2))
        #expect(RemoteRdSurfaceStreamChange(.object(["t": .string("rb.surface.hide"), "surface": .int(4)])) == .hide(surface: 4))
        // Stream 0 is the page's.
        #expect(RemoteRdSurfaceStreamChange(.object(["t": .string("rb.surface.show"), "surface": .int(4), "stream": .int(0)])) == nil)
        #expect(RemoteRdSurfaceStreamChange(.object(["t": .string("rb.page"), "surface": .int(4)])) == nil)
    }
}
