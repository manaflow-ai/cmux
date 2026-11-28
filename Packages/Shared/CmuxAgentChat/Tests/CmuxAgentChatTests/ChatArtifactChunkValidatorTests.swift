import Foundation
import Testing

@testable import CmuxAgentChat

@Suite
struct ChatArtifactChunkValidatorTests {
    @Test
    func acceptsOrderedExactSizeTransfer() throws {
        var validator = ChatArtifactChunkValidator(expectedSize: 3)

        try validator.receive(ChatArtifactChunk(
            data: Data("ab".utf8),
            offset: 0,
            totalSize: 3,
            eof: false
        ))
        try validator.receive(ChatArtifactChunk(
            data: Data("c".utf8),
            offset: 2,
            totalSize: 3,
            eof: true
        ))

        try validator.finish()
    }

    @Test
    func changedTotalDoesNotMasqueradeAsConnectionLoss() throws {
        var validator = ChatArtifactChunkValidator(expectedSize: 3)

        #expect(throws: ChatArtifactError.fileChanged) {
            try validator.receive(ChatArtifactChunk(
                data: Data("abcd".utf8),
                offset: 0,
                totalSize: 4,
                eof: true
            ))
        }
    }

    @Test
    func rejectsMalformedOffsetsAndEOF() throws {
        var negativeExpectedSize = ChatArtifactChunkValidator(expectedSize: -1)
        #expect(throws: ChatArtifactError.invalidResponse) {
            try negativeExpectedSize.receive(ChatArtifactChunk(
                data: Data(),
                offset: 0,
                totalSize: 0,
                eof: true
            ))
        }

        var offsetValidator = ChatArtifactChunkValidator()
        #expect(throws: ChatArtifactError.invalidResponse) {
            try offsetValidator.receive(ChatArtifactChunk(
                data: Data("a".utf8),
                offset: 1,
                totalSize: 2,
                eof: false
            ))
        }

        var eofValidator = ChatArtifactChunkValidator()
        #expect(throws: ChatArtifactError.invalidResponse) {
            try eofValidator.receive(ChatArtifactChunk(
                data: Data("a".utf8),
                offset: 0,
                totalSize: 2,
                eof: true
            ))
        }
    }

    @Test
    func producerEndingWithoutEOFIsInterrupted() throws {
        var validator = ChatArtifactChunkValidator(expectedSize: 2)
        try validator.receive(ChatArtifactChunk(
            data: Data("a".utf8),
            offset: 0,
            totalSize: 2,
            eof: false
        ))

        #expect(throws: ChatArtifactError.transferInterrupted) {
            try validator.finish()
        }
    }
}
