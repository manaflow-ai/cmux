import Foundation
import Testing
@testable import CmuxNextDaemon

/// The shared connection's byte stream carries JSON lines and binary attach
/// frames (`attach-frames-v1`); the reader cuts them apart at any read boundary.
@Suite struct WireSplitterTests {
    private func frame(_ kind: AttachFrameKind, stream: UInt16, offset: UInt64, _ payload: Data) -> Data {
        AttachFrameHeader(kind: kind, stream: stream, length: payload.count, offset: offset).encoded + payload
    }

    private func split(_ wire: Data, chunk: Int) throws -> [WireSplitter.Message] {
        var splitter = WireSplitter()
        var messages: [WireSplitter.Message] = []
        var index = wire.startIndex
        while index < wire.endIndex {
            let end = min(index + chunk, wire.endIndex)
            try wire[index..<end].withUnsafeBytes { raw in
                try splitter.append(raw) { messages.append($0) }
            }
            index = end
        }
        #expect(splitter.bufferedBytes == 0)
        return messages
    }

    @Test func linesAndFramesComeApartAtEveryReadBoundary() throws {
        // A payload holding newlines and 0xFF: a frame is never searched for either.
        let output = Data("ls\r\n\u{1b}[1m".utf8) + Data([0xFF, 0x0A, 0x00])
        let wire = Data(#"{"id":1,"ok":true}"#.utf8) + Data([0x0A])
            + frame(.output, stream: 513, offset: 1 << 33, output)
            + Data("\n".utf8)  // an empty line between messages is skipped
            + frame(.ringAdvance, stream: 2, offset: 9, Data())
            + Data(#"{"event":"x","stream":2}"#.utf8) + Data([0x0A])
        let expected: [WireSplitter.Message] = [
            .line(Data(#"{"id":1,"ok":true}"#.utf8)),
            .frame(AttachFrameHeader(kind: .output, stream: 513, length: output.count, offset: 1 << 33), output),
            .frame(AttachFrameHeader(kind: .ringAdvance, stream: 2, length: 0, offset: 9), Data()),
            .line(Data(#"{"event":"x","stream":2}"#.utf8)),
        ]
        for chunk in 1...wire.count {
            #expect(try split(wire, chunk: chunk) == expected, "read size \(chunk)")
        }
    }

    @Test func aMalformedHeaderEndsTheStream() {
        var bad = AttachFrameHeader(kind: .output, stream: 1, length: 0, offset: 0).encoded
        bad[1] = 99
        var splitter = WireSplitter()
        #expect(throws: AttachFrameHeader.DecodeError.kind(99)) {
            try bad.withUnsafeBytes { raw in try splitter.append(raw) { _ in } }
        }
        var zeroStream = AttachFrameHeader(kind: .output, stream: 1, length: 0, offset: 0).encoded
        zeroStream[2] = 0
        var other = WireSplitter()
        #expect(throws: AttachFrameHeader.DecodeError.stream) {
            try zeroStream.withUnsafeBytes { raw in try other.append(raw) { _ in } }
        }
    }

    @Test func aLongLineIsSearchedForItsNewlineOnce() throws {
        let line = Data(repeating: UInt8(ascii: "a"), count: 1 << 20) + Data([0x0A])
        var splitter = WireSplitter()
        var lines = 0
        var index = line.startIndex
        while index < line.endIndex {
            let end = min(index + 4096, line.endIndex)
            try line[index..<end].withUnsafeBytes { raw in try splitter.append(raw) { _ in lines += 1 } }
            index = end
        }
        #expect(lines == 1)
        #expect(splitter.scannedBytes == line.count, "each byte is searched once")
    }

    @Test func aFrameMetaSplitsIntoItsJSONAndItsData() throws {
        let meta = Data(#"{"phase":"ready"}"#.utf8)
        var payload = Data([UInt8(meta.count), 0, 0, 0]) + meta + Data([0xFF, 1, 2])
        let parts = try #require(AttachFrameMeta(payload))
        #expect(parts.meta == meta)
        #expect(parts.data == Data([0xFF, 1, 2]))
        payload[0] = 200
        #expect(AttachFrameMeta(payload) == nil, "a meta length past the payload is refused")
    }
}
