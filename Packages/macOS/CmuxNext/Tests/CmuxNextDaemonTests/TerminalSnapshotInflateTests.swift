import Foundation
import Testing
@testable import CmuxNextDaemon

/// p15-oracle-130: a `terminal-snapshot-history-v1` chunk inflates to the same bytes through Compression on macOS
/// and zlib on Linux. The chunks are raw DEFLATE from another encoder (Python's zlib with wbits -15, as the host's
/// flate2 writes them), at least one per block type (BTYPE 0, 1 and 2, checked below), so neither platform's
/// decoder checks itself.
@Suite struct TerminalSnapshotInflateTests {
    private static let history = Data(String(repeating: "cmux snapshot history\r\n", count: 40).utf8)
    /// `history`, one fixed Huffman block of back references (level 9: zlib keeps the fixed codes for this run).
    private static let fixedRepeatChunk = Data([75, 206, 45, 173, 80, 40, 206, 75, 44, 40, 206, 200, 47, 81, 200, 200, 44, 46, 201,
                                                47, 170, 228, 229, 74, 30, 21, 30, 21, 30, 21, 30, 56, 97, 0])
    /// Sixteen varied terminal lines (colored prompts, commands, paths), as a history chunk holds.
    private static let terminalLines: Data = {
        let words = ["ls", "cd", "git", "cargo", "make", "echo", "vim", "grep"]
        let text = (0..<16).map { line in
            "\u{1B}[32m\(String(format: "%03d", line))\u{1B}[0m \(words[line % 8]) --flag=\(line * 37 % 101) "
                + "path/\(words[line * 5 % 8])/\(line * line % 97)\r\n"
        }.joined()
        return Data(text.utf8)
    }()
    /// `terminalLines`, one dynamic Huffman block (level 9), as flate2 writes almost every real history chunk:
    /// `zlib.compressobj(9, zlib.DEFLATED, -15)`.
    private static let dynamicChunk = Data([
        101, 208, 59, 14, 131, 48, 12, 128, 225, 189, 82, 79, 192, 194, 5, 144, 157, 56, 16, 24, 122, 18, 38, 4,
        20, 80, 65, 84, 128, 122, 254, 66, 30, 14, 130, 53, 250, 20, 219, 127, 84, 146, 156, 16, 49, 42, 113, 138,
        199, 53, 78, 146, 247, 88, 117, 47, 140, 191, 213, 214, 195, 184, 2, 62, 31, 145, 53, 194, 152, 186, 241, 134,
        180, 69, 109, 221, 207, 32, 152, 73, 195, 186, 97, 243, 78, 43, 235, 246, 39, 80, 204, 200, 254, 86, 45, 221,
        236, 161, 112, 83, 187, 165, 253, 66, 193, 82, 25, 57, 85, 159, 214, 67, 229, 38, 31, 111, 32, 50, 150, 169,
        145, 199, 62, 94, 230, 110, 118, 221, 128, 76, 217, 101, 198, 253, 134, 201, 51, 233, 38, 239, 79, 64, 225, 63,
        109, 79, 217, 215, 241, 48, 117, 147, 205, 222, 160, 194, 146, 249, 37, 96, 161, 184, 96, 22, 142, 46, 174, 9,
        241, 148, 48, 231, 134, 2, 175, 13, 51, 29, 26, 18, 51, 113, 111, 72, 167, 132, 146, 7, 11, 121, 111, 136,
        167, 134, 74, 179, 164, 91, 67, 173, 185, 161, 150, 236, 212, 181, 161, 160, 208, 48, 176, 244, 158, 16, 207, 9,
        105, 63, 250, 15,
    ])
    /// "hello", a fixed Huffman block (level 6).
    private static let fixedChunk = Data([203, 72, 205, 201, 201, 7, 0])
    /// "hello", a stored block (level 0).
    private static let storedChunk = Data([1, 5, 0, 250, 255, 104, 101, 108, 108, 111])

    /// BTYPE of a chunk's first block: bits 1-2 of its first byte (RFC 1951 3.2.3).
    private static func blockType(_ chunk: Data) -> UInt8? {
        chunk.first.map { ($0 >> 1) & 3 }
    }

    @Test func theFixturesCoverEveryBlockType() {
        #expect(Self.terminalLines.count == 644)
        #expect(Self.blockType(Self.storedChunk) == 0)
        #expect(Self.blockType(Self.fixedChunk) == 1)
        #expect(Self.blockType(Self.fixedRepeatChunk) == 1)
        #expect(Self.blockType(Self.dynamicChunk) == 2)
    }

    @Test func inflatesEachBlockTypeToItsRawBytes() {
        let hello = Data("hello".utf8)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate", rawBytes: Self.terminalLines.count)
            == Self.terminalLines)
        #expect(TerminalSnapshotInflate.inflate(Self.fixedRepeatChunk, compression: "deflate", rawBytes: Self.history.count)
            == Self.history)
        #expect(TerminalSnapshotInflate.inflate(Self.fixedChunk, compression: "deflate", rawBytes: hello.count) == hello)
        #expect(TerminalSnapshotInflate.inflate(Self.storedChunk, compression: "deflate", rawBytes: hello.count) == hello)
    }

    @Test func refusesAChunkWhoseSizeIsNotRawBytes() {
        let size = Self.terminalLines.count
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate", rawBytes: size - 1) == nil)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "deflate", rawBytes: size + 1) == nil)
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk.prefix(Self.dynamicChunk.count / 2), compression: "deflate",
                                                rawBytes: size) == nil)
        #expect(TerminalSnapshotInflate.inflate(Self.fixedRepeatChunk, compression: "deflate", rawBytes: Self.history.count - 1) == nil)
    }

    @Test func refusesUnknownCodecsAndSizesOverTheCap() {
        let size = Self.terminalLines.count
        #expect(TerminalSnapshotInflate.inflate(Self.dynamicChunk, compression: "zstd", rawBytes: size) == nil)
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
