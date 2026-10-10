import Compression
import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-snapshot-history-v1` history chunks travel as raw DEFLATE
/// (`compression: "deflate"`, `raw_bytes`); the attach reader inflates them,
/// so the view gets the snapshot bytes it restores.
@Suite struct TerminalSnapshotCompressionTests {
    private func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(written)
    }

    private func history(_ fields: String) -> Data {
        Data(#"{"event":"snapshot","surface":3,"phase":"history","generation":2,"offset":9,"version":1,\#(fields)}"#.utf8)
    }

    @Test func aDeflatedHistoryChunkInflatesToItsBytes() {
        let raw = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 % 7) })
        let packed = deflate(raw)
        #expect(packed.count < raw.count)
        let line = history(#""compression":"deflate","raw_bytes":\#(raw.count),"done":false,"data":"\#(packed.base64EncodedString())""#)
        guard case .snapshot(let frame) = TerminalAttachment.decodeAttachEvent(name: "snapshot", line: line, surface: 3) else {
            Issue.record("expected a history snapshot")
            return
        }
        #expect(frame.phase == .history)
        #expect(frame.data == raw)
    }

    /// A chunk that does not inflate to its stated size, or uses another
    /// codec, is not a view event (its bytes would corrupt the restore).
    @Test func aBadOrUnknownCompressionIsDropped() {
        let raw = Data(repeating: 0x41, count: 4096)
        let packed = deflate(raw).base64EncodedString()
        let wrongSize = history(#""compression":"deflate","raw_bytes":4000,"data":"\#(packed)""#)
        #expect(TerminalAttachment.decodeAttachEvent(name: "snapshot", line: wrongSize, surface: 3) == nil)
        let unknown = history(#""compression":"zstd","raw_bytes":4096,"data":"\#(packed)""#)
        #expect(TerminalAttachment.decodeAttachEvent(name: "snapshot", line: unknown, surface: 3) == nil)
        let huge = history(#""compression":"deflate","raw_bytes":1073741824,"data":"\#(packed)""#)
        #expect(TerminalAttachment.decodeAttachEvent(name: "snapshot", line: huge, surface: 3) == nil)
    }
}
