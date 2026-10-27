import Foundation
import Testing
@testable import CmuxNextDaemon

/// p15-oracle-130: a `terminal-snapshot-history-v1` chunk inflates to the same bytes through Compression on macOS
/// and zlib on Linux. The chunks are raw DEFLATE from another encoder (Python's zlib with wbits -15, as the host's
/// flate2 writes them), one per block type, so neither platform's decoder checks itself.
@Suite struct TerminalSnapshotInflateTests {
    private static let history = Data(String(repeating: "cmux snapshot history\r\n", count: 40).utf8)
    /// `history`, dynamic Huffman blocks (level 9).
    private static let dynamicChunk = Data([75, 206, 45, 173, 80, 40, 206, 75, 44, 40, 206, 200, 47, 81, 200, 200, 44, 46, 201,
                                            47, 170, 228, 229, 74, 30, 21, 30, 21, 30, 21, 30, 56, 97, 0])
    /// "hello", a fixed Huffman block (level 6).
    private static let fixedChunk = Data([203, 72, 205, 201, 201, 7, 0])
    /// "hello", a stored block (level 0).
    private static let storedChunk = Data([1, 5, 0, 250, 255, 104, 101, 108, 108, 111])

    @Test func inflatesEachBlockTypeToItsRawBytes() {
        let hello = Data("hello".utf8)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate", rawBytes: Self.history.count) == Self.history)
        #expect(TerminalSnapshotInflate.inflate(Self.fixedChunk, compression: "deflate", rawBytes: hello.count) == hello)
        #expect(TerminalSnapshotInflate.inflate(Self.storedChunk, compression: "deflate", rawBytes: hello.count) == hello)
    }

    @Test func refusesAChunkWhoseSizeIsNotRawBytes() {
        let size = Self.history.count
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate", rawBytes: size - 1) == nil)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate", rawBytes: size + 1) == nil)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk.prefix(Self.dynamicChunk.count / 2), compression: "deflate",
                                                rawBytes: size) == nil)
    }

    @Test func refusesUnknownCodecsAndSizesOverTheCap() {
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "zstd", rawBytes: Self.history.count) == nil)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate",
                                                rawBytes: TerminalSnapshotInflate.maxRawBytes + 1) == nil)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate", rawBytes: nil) == nil)
    }

    @Test func passesUncompressedAndEmptyChunks() {
        #expect(TerminalSnapshotInflate.inflate(Self.history, compression: nil, rawBytes: nil) == Self.history)
        #expect(TerminalSnapshotInflate.inflate(Data(), compression: "deflate", rawBytes: 0) == Data())
        #expect(TerminalSnapshotInflate.inflate(Self.fixedChunk, compression: "deflate", rawBytes: 0) == nil)
    }
}
