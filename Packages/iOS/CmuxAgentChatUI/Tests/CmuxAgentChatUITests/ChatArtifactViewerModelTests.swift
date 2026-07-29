import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite
struct ChatArtifactViewerModelTests {
    @Test("large transport chunks are published in bounded UI batches")
    @MainActor
    func batchesLargeTransportChunks() async {
        let line = "0123456789abcdef 漢🙂\n"
        let text = String(repeating: line, count: 20_000)
        let data = Data(text.utf8)
        let loader = Self.loader(totalSize: Int64(data.count)) { _, onChunk in
            try await onChunk(ChatArtifactChunk(
                data: data,
                offset: 0,
                totalSize: Int64(data.count),
                eof: true
            ))
        }
        let model = ChatArtifactViewerModel()

        await model.load(path: "/tmp/large.log", loader: loader)

        #expect(model.textChunks.count > 1)
        #expect(model.textChunks.allSatisfy { $0.utf8.count <= 262_160 })
        #expect(model.renderedText == text)
        #expect(model.textReachedEOF)
    }

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

    @Test
    @MainActor
    func mediaUsesMediaCapAndRejectsFromStatBeforeFetch() async {
        let limit = ChatArtifactTransferPolicy.defaultPolicy.maxMediaPreviewBytes
        let streamCalls = ArtifactStreamCallCounter()
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: limit + 1,
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    kind: .binary,
                    mimeType: "video/mp4"
                )
            },
            stream: { _, _ in
                await streamCalls.recordCall()
            }
        )
        let model = ChatArtifactViewerModel()

        await model.load(path: "/remote/movie.mp4", loader: loader)

        #expect(model.state == .tooLarge(actualSize: limit + 1, limit: limit))
        #expect(await streamCalls.callCount() == 0)
    }

    @Test
    @MainActor
    func mediaStreamsToExtensionPreservingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-media-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("media bytes".utf8)
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: Int64(data.count),
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    kind: .binary,
                    mimeType: "video/mp4"
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

        await model.load(path: "/remote/movie.mp4", loader: loader)

        guard case .media(let fileURL) = model.state else {
            Issue.record("movie metadata should route to the media file state")
            return
        }
        #expect(fileURL.pathExtension == "mp4")
        #expect(try Data(contentsOf: fileURL) == data)
        await model.cleanup()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    @MainActor
    func quickLookRequiresCapabilityAcceptance() async throws {
        let acceptedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-ql-accepted-\(UUID().uuidString)", isDirectory: true)
        let rejectedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-ql-rejected-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: acceptedDirectory)
            try? FileManager.default.removeItem(at: rejectedDirectory)
        }
        let data = Data("document bytes".utf8)
        let loader = Self.quickLookLoader(data: data)
        let acceptedModel = ChatArtifactViewerModel(
            temporaryFileStore: ChatArtifactTemporaryFileStore(directory: acceptedDirectory)
        )
        let rejectedModel = ChatArtifactViewerModel(
            temporaryFileStore: ChatArtifactTemporaryFileStore(directory: rejectedDirectory)
        )

        await acceptedModel.load(
            path: "/remote/report.docx",
            loader: loader,
            quickLookCanPreview: { _ in true }
        )
        await rejectedModel.load(
            path: "/remote/report.docx",
            loader: loader,
            quickLookCanPreview: { _ in false }
        )

        guard case .quickLook(let acceptedURL) = acceptedModel.state else {
            Issue.record("accepted document should route to Quick Look")
            return
        }
        #expect(acceptedURL.pathExtension == "docx")
        #expect(try Data(contentsOf: acceptedURL) == data)
        guard case .binary = rejectedModel.state else {
            Issue.record("rejected document should retain the binary state")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: rejectedDirectory.path).isEmpty)
        await acceptedModel.cleanup()
        #expect(!FileManager.default.fileExists(atPath: acceptedURL.path))
    }

    @Test
    @MainActor
    func markdownStreamsAsTextAndAppliesRawOnlyThreshold() async {
        let markdown = Data("# Heading\n\nBody".utf8)
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: ChatArtifactMarkdownPresentation.maximumRenderedByteCount + 1,
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    kind: .text,
                    mimeType: "text/markdown"
                )
            },
            stream: { _, onChunk in
                try await onChunk(ChatArtifactChunk(
                    data: markdown,
                    offset: 0,
                    totalSize: Int64(markdown.count),
                    eof: true
                ))
            }
        )
        let model = ChatArtifactViewerModel()

        await model.load(path: "/remote/README.md", loader: loader)

        #expect(model.state == .markdown)
        #expect(model.renderedText == "# Heading\n\nBody")
        #expect(model.markdownPresentation.mode == .raw)
        #expect(!model.markdownPresentation.isRenderedAvailable)
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

    private static func quickLookLoader(data: Data) -> ChatArtifactLoader {
        ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: Int64(data.count),
                    modifiedAt: Date(timeIntervalSince1970: 0),
                    kind: .binary,
                    mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
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
    }
}
