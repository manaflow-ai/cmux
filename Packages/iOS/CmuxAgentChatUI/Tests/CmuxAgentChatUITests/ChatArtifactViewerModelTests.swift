import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite
struct ChatArtifactViewerModelTests {
    @Test
    @MainActor
    func exposesFirstChunkBeforeEOFAndCompletesProgress() async throws {
        let firstData = Data("first 漢".utf8)
        let lastData = Data("🙂 last".utf8)
        let totalSize = Int64(firstData.count + lastData.count)
        let stream = ControlledArtifactStream(chunks: [
            ChatArtifactChunk(
                data: firstData,
                offset: 0,
                totalSize: totalSize,
                eof: false
            ),
            ChatArtifactChunk(
                data: lastData,
                offset: Int64(firstData.count),
                totalSize: totalSize,
                eof: true
            ),
        ])
        let loader = Self.loader(totalSize: totalSize) { _, onChunk in
            try await stream.fetch(onChunk: onChunk)
        }
        let model = ChatArtifactViewerModel()

        let loadTask = Task {
            await model.load(path: "/tmp/progressive.txt", loader: loader)
        }
        await stream.waitUntilFirstChunkDelivered()

        #expect(model.state == .text)
        #expect(model.renderedText == "first 漢")
        #expect(!model.textReachedEOF)
        #expect(model.fetchedBytes == Int64(firstData.count))
        #expect(model.totalBytes == totalSize)

        await stream.resume()
        await loadTask.value

        #expect(model.renderedText == "first 漢🙂 last")
        #expect(model.textReachedEOF)
        #expect(model.fetchedBytes == totalSize)
        #expect(model.totalBytes == totalSize)
    }

    @Test
    @MainActor
    func pathChangeCancellationStopsThePreviousStream() async {
        let firstPathData = Data("old".utf8)
        let staleData = Data(" stale".utf8)
        let staleTotalSize = Int64(firstPathData.count + staleData.count)
        let blockedStream = ControlledArtifactStream(chunks: [
            ChatArtifactChunk(
                data: firstPathData,
                offset: 0,
                totalSize: staleTotalSize,
                eof: false
            ),
            ChatArtifactChunk(
                data: staleData,
                offset: Int64(firstPathData.count),
                totalSize: staleTotalSize,
                eof: true
            ),
        ])
        let newData = Data("new path".utf8)
        let loader = Self.loader(totalSize: Int64(newData.count)) { path, onChunk in
            if path == "/tmp/old.txt" {
                try await blockedStream.fetch(onChunk: onChunk)
                return
            }
            try await onChunk(
                ChatArtifactChunk(
                    data: newData,
                    offset: 0,
                    totalSize: Int64(newData.count),
                    eof: true
                )
            )
        }
        let model = ChatArtifactViewerModel()

        let oldTask = Task {
            await model.load(path: "/tmp/old.txt", loader: loader)
        }
        await blockedStream.waitUntilFirstChunkDelivered()
        oldTask.cancel()
        let newTask = Task {
            await model.load(path: "/tmp/new.txt", loader: loader)
        }

        await blockedStream.waitUntilCancelled()
        await oldTask.value
        await newTask.value

        #expect(model.activePath == "/tmp/new.txt")
        #expect(model.renderedText == "new path")
        #expect(model.textReachedEOF)
    }

    @Test
    @MainActor
    func tooLargeStateRetainsActualFileSize() async {
        let limit = ChatArtifactTransferPolicy.defaultPolicy.maxPreviewBytes
        let actualSize = limit + 42
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: actualSize,
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    kind: .text,
                    mimeType: "text/plain"
                )
            }
        )
        let model = ChatArtifactViewerModel()

        await model.load(path: "/tmp/too-large.txt", loader: loader)

        #expect(model.state == .tooLarge(actualSize: actualSize, limit: limit))
    }

    @Test
    @MainActor
    func pdfStreamsToTemporaryFileAndCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-pdf-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("%PDF-test".utf8)
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: Int64(data.count),
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    kind: .binary,
                    mimeType: "application/pdf"
                )
            },
            stream: { _, onChunk in
                try await onChunk(ChatArtifactChunk(
                    data: data,
                    offset: 0,
                    totalSize: Int64(data.count),
                    eof: true
                ))
            }
        )
        let model = ChatArtifactViewerModel(
            temporaryFileStore: ChatArtifactTemporaryFileStore(directory: directory)
        )

        await model.load(path: "/remote/report", loader: loader)

        guard case .pdf(let fileURL) = model.state else {
            Issue.record("PDF metadata should route to the PDF file state")
            return
        }
        #expect(fileURL.pathExtension == "pdf")
        #expect(try Data(contentsOf: fileURL) == data)
        await model.cleanup()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    private static func loader(
        totalSize: Int64,
        stream: @escaping @Sendable (
            _ path: String,
            _ onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
        ) async throws -> Void
    ) -> ChatArtifactLoader {
        ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: totalSize,
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    kind: .text,
                    mimeType: "text/plain"
                )
            },
            stream: stream
        )
    }
}
