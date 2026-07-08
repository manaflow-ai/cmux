import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

struct ChatArtifactLoaderTests {
    @Test func thumbnailCacheReusesSamePathAndDimension() async throws {
        let source = CountingArtifactSource()
        let loader = ChatArtifactLoader(
            source: source,
            sessionID: "session-1",
            cache: ChatArtifactThumbnailCache()
        )

        let first = try await loader.thumbnail(path: "/tmp/image.png", maxDimension: 256)
        let second = try await loader.thumbnail(path: "/tmp/image.png", maxDimension: 256)
        let third = try await loader.thumbnail(path: "/tmp/image.png", maxDimension: 512)

        #expect(first.data == Data([1, 2, 3]))
        #expect(second.data == Data([1, 2, 3]))
        #expect(third.data == Data([1, 2, 3]))
        #expect(first.pixelWidth == 256)
        #expect(second.pixelWidth == 256)
        #expect(third.pixelWidth == 512)
        #expect(await source.thumbnailRequestCount() == 2)
    }
}

private actor CountingArtifactSource: ChatEventSource {
    nonisolated let supportsArtifacts = true
    private var requests = 0

    func thumbnailRequestCount() -> Int {
        requests
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        throw ChatArtifactError.unsupported
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        throw ChatArtifactError.unsupported
    }

    func interrupt(sessionID: String, hard: Bool) async throws {
        throw ChatArtifactError.unsupported
    }

    func answer(optionIndex: Int, sessionID: String) async throws {
        throw ChatArtifactError.unsupported
    }

    func artifactStat(sessionID: String, path: String) async throws -> ChatArtifactStat {
        throw ChatArtifactError.unsupported
    }

    func artifactFetch(
        sessionID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data {
        throw ChatArtifactError.unsupported
    }

    func artifactThumbnail(
        sessionID: String,
        path: String,
        maxDimension: Int
    ) async throws -> ChatArtifactThumbnail {
        requests += 1
        return ChatArtifactThumbnail(data: Data([1, 2, 3]), pixelWidth: maxDimension, pixelHeight: maxDimension)
    }

    func artifactList(sessionID: String, path: String) async throws -> ChatArtifactDirectoryListing {
        throw ChatArtifactError.unsupported
    }
}
