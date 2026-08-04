import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact temporary files")
struct ChatArtifactTemporaryFileStoreTests {
    @Test("writes streamed chunks to a file with the requested extension")
    func writesChunks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-temp-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Data("PDF".utf8)
        let second = Data(" bytes".utf8)
        let totalSize = Int64(first.count + second.count)
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stream: { _, onChunk in
                try await onChunk(ChatArtifactChunk(
                    data: first,
                    offset: 0,
                    totalSize: totalSize,
                    eof: false
                ))
                try await onChunk(ChatArtifactChunk(
                    data: second,
                    offset: Int64(first.count),
                    totalSize: totalSize,
                    eof: true
                ))
            }
        )
        let store = ChatArtifactTemporaryFileStore(directory: directory)

        let fileURL = try await store.fetch(
            path: "/remote/report",
            expectedSize: totalSize,
            limit: 1024,
            fallbackExtension: "pdf",
            loader: loader,
            progress: { _ in }
        )

        #expect(fileURL.pathExtension == "pdf")
        #expect(try Data(contentsOf: fileURL) == first + second)
        await store.remove(fileURL)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("cancellation removes a partially written file")
    func cancellationRemovesPartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-cancel-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Data("partial".utf8)
        let second = Data(" remainder".utf8)
        let totalSize = Int64(first.count + second.count)
        let stream = ControlledArtifactStream(chunks: [
            ChatArtifactChunk(data: first, offset: 0, totalSize: totalSize, eof: false),
            ChatArtifactChunk(
                data: second,
                offset: Int64(first.count),
                totalSize: totalSize,
                eof: true
            ),
        ])
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stream: { _, onChunk in
                try await stream.fetch(onChunk: onChunk)
            }
        )
        let store = ChatArtifactTemporaryFileStore(directory: directory)
        let fetchTask = Task {
            try await store.fetch(
                path: "/remote/movie.mp4",
                expectedSize: totalSize,
                limit: 512 * 1024 * 1024,
                loader: loader,
                progress: { _ in }
            )
        }

        await stream.waitUntilFirstChunkDelivered()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        fetchTask.cancel()
        await stream.waitUntilCancelled()
        do {
            _ = try await fetchTask.value
            Issue.record("cancelled fetch should throw")
        } catch is CancellationError {
            // Expected structured cancellation.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
