import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact viewer present-first routing")
struct ChatArtifactViewerPresentationRoutingTests {
    @Test(
        "presents the destination before a blocking route finishes",
        arguments: ["/remote/README.md", "/remote/report.pdf"]
    )
    @MainActor
    func presentsBeforeRouteFinishes(path: String) async throws {
        let isMarkdown = path.hasSuffix(".md")
        let firstData = Data((isMarkdown ? "# Heading\n" : "%PDF-first").utf8)
        let lastData = Data((isMarkdown ? "\nBody" : "-last").utf8)
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
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: totalSize,
                    modifiedAt: Date(timeIntervalSince1970: 1),
                    kind: isMarkdown ? .text : .binary,
                    mimeType: isMarkdown ? "text/markdown" : "application/pdf"
                )
            },
            stream: { _, onChunk in
                try await stream.fetch(onChunk: onChunk)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-present-first-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ChatArtifactViewerModel(
            temporaryFileStore: ChatArtifactTemporaryFileStore(directory: directory)
        )
        let presentation = ChatArtifactViewerPresentationCoordinator()

        presentation.present()
        let loadTask = Task {
            await presentation.loadAfterPresentation {
                await model.load(path: path, loader: loader)
            }
        }
        await stream.waitUntilFirstChunkDelivered()

        #expect(presentation.isPresented)
        #expect(model.fetchedBytes == Int64(firstData.count))
        #expect(model.fetchedBytes < totalSize)
        if isMarkdown {
            #expect(model.state == .markdown)
        } else {
            #expect(model.state == .loading)
        }

        await stream.resume()
        _ = await loadTask.value

        if isMarkdown {
            #expect(model.state == .markdown)
        } else if case .pdf = model.state {
            // The fully fetched PDF resolved in-page after presentation.
        } else {
            Issue.record("Expected the PDF route to resolve after presentation")
        }
        await model.cleanup()
    }
}
