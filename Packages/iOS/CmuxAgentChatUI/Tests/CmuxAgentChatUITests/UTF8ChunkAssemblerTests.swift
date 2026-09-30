import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite
struct UTF8ChunkAssemblerTests {
    @Test
    func preservesCJKAndEmojiAcrossEveryByteBoundary() throws {
        let expected = "start 漢字🙂終わり end"
        let data = Data(expected.utf8)

        for boundary in 1..<data.count {
            var assembler = UTF8ChunkAssembler()
            let first = try assembler.append(data.prefix(boundary), eof: false)
            let second = try assembler.append(data.dropFirst(boundary), eof: true)
            #expect(first + second == expected, "failed at byte boundary \(boundary)")
        }
    }

    @Test
    func assemblesOneByteChunks() throws {
        let expected = "漢🙂字"
        let bytes = Array(expected.utf8)
        var assembler = UTF8ChunkAssembler()
        var result = ""

        for (index, byte) in bytes.enumerated() {
            result += try assembler.append(
                Data([byte]),
                eof: index == bytes.index(before: bytes.endIndex)
            )
        }

        #expect(result == expected)
    }

    @Test
    func rejectsIncompleteScalarAtEOF() {
        var assembler = UTF8ChunkAssembler()

        #expect(throws: UTF8ChunkAssemblerError.invalidEncoding) {
            try assembler.append(Data([0xF0, 0x9F, 0x99]), eof: true)
        }
    }
}
