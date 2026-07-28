import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite
struct MobileArtifactChunkFetchLoopTests {
    @Test
    func sequencesOffsetsAndStopsAtEOF() async throws {
        let first = ChatArtifactChunk(
            data: Data("abc".utf8),
            offset: 0,
            totalSize: 5,
            eof: false
        )
        let last = ChatArtifactChunk(
            data: Data("de".utf8),
            offset: 3,
            totalSize: 5,
            eof: true
        )
        let script = MobileArtifactChunkScript(chunks: [first, last])

        _ = try await MobileArtifactChunkFetchLoop().run(
            collectsData: false,
            progress: nil
        ) { offset in
            try await script.fetch(offset: offset)
        } onChunk: { chunk in
            await script.record(chunk)
        }

        let snapshot = await script.snapshot()
        #expect(snapshot.requestedOffsets == [0, 3])
        #expect(snapshot.deliveredChunks == [first, last])
    }

    @Test
    func acceptsEmptyEOFChunk() async throws {
        let emptyEOF = ChatArtifactChunk(
            data: Data(),
            offset: 0,
            totalSize: 0,
            eof: true
        )
        let script = MobileArtifactChunkScript(chunks: [emptyEOF])

        _ = try await MobileArtifactChunkFetchLoop().run(
            collectsData: false,
            progress: nil
        ) { offset in
            try await script.fetch(offset: offset)
        } onChunk: { chunk in
            await script.record(chunk)
        }

        let snapshot = await script.snapshot()
        #expect(snapshot.requestedOffsets == [0])
        #expect(snapshot.deliveredChunks == [emptyEOF])
    }

    @Test
    func rejectsEmptyNonEOFChunkAsMacUnreachable() async {
        let stalled = ChatArtifactChunk(
            data: Data(),
            offset: 0,
            totalSize: 8,
            eof: false
        )
        let script = MobileArtifactChunkScript(chunks: [stalled])

        do {
            _ = try await MobileArtifactChunkFetchLoop().run(
                collectsData: false,
                progress: nil
            ) { offset in
                try await script.fetch(offset: offset)
            } onChunk: { chunk in
                await script.record(chunk)
            }
            Issue.record("empty non-EOF chunk should fail")
        } catch let error as ChatArtifactError {
            #expect(error == .macUnreachable)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let snapshot = await script.snapshot()
        #expect(snapshot.requestedOffsets == [0])
        #expect(snapshot.deliveredChunks == [stalled])
    }
}
