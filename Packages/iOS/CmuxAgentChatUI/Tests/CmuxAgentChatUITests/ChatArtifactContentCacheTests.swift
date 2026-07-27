import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Chat artifact content cache")
struct ChatArtifactContentCacheTests {
    @Test("mtime and size changes invalidate the content key")
    func keyInvalidation() throws {
        let base = try #require(ChatArtifactContentCache.key(
            scopeKey: "chat:session",
            path: "/tmp/report.txt",
            modifiedAt: Date(timeIntervalSince1970: 10),
            size: 3
        ))
        let changedMTime = try #require(ChatArtifactContentCache.key(
            scopeKey: "chat:session",
            path: "/tmp/report.txt",
            modifiedAt: Date(timeIntervalSince1970: 11),
            size: 3
        ))
        let changedSize = try #require(ChatArtifactContentCache.key(
            scopeKey: "chat:session",
            path: "/tmp/report.txt",
            modifiedAt: Date(timeIntervalSince1970: 10),
            size: 4
        ))

        #expect(base != changedMTime)
        #expect(base != changedSize)
    }

    @Test("disk budget evicts the least recently used content")
    func diskLRUEviction() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatArtifactContentCache(
            directory: directory,
            maxDiskBytes: 6,
            maxMemoryBytes: 0
        )
        let source = CountingContentSource(values: [
            "a": Data([1, 1, 1]),
            "b": Data([2, 2, 2]),
            "c": Data([3, 3, 3]),
        ])

        try await stream(key: "a", at: 1, cache: cache, source: source)
        try await stream(key: "b", at: 2, cache: cache, source: source)
        try await stream(key: "a", at: 3, cache: cache, source: source)
        try await stream(key: "c", at: 4, cache: cache, source: source)
        try await stream(key: "a", at: 5, cache: cache, source: source)
        try await stream(key: "b", at: 6, cache: cache, source: source)

        #expect(await source.fetchCount(for: "a") == 1)
        #expect(await source.fetchCount(for: "b") == 2)
        #expect(await source.fetchCount(for: "c") == 1)
    }

    @Test("reopening unchanged viewer content performs no second fetch")
    @MainActor
    func viewerInstantHit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CountingContentSource(values: ["artifact": Data("hello".utf8)])
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            scope: .chat(sessionID: "session"),
            contentCache: ChatArtifactContentCache(directory: directory),
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: 5,
                    modifiedAt: modifiedAt,
                    kind: .text,
                    mimeType: "text/plain"
                )
            },
            fetch: { _, _ in Data("hello".utf8) },
            stream: { _, receive in
                try await source.fetch(key: "artifact", receive: receive)
            }
        )

        let first = ChatArtifactViewerModel()
        await first.load(path: "/tmp/artifact.txt", loader: loader)
        let second = ChatArtifactViewerModel()
        await second.load(path: "/tmp/artifact.txt", loader: loader)

        #expect(first.renderedText == "hello")
        #expect(second.renderedText == "hello")
        #expect(await source.fetchCount(for: "artifact") == 1)
    }

    @Test("unsupported loader scopes never share cached bytes")
    func unsupportedScopeBypassesCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("fixture".utf8)
        let source = CountingContentSource(values: ["fixture": bytes])
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            contentCache: ChatArtifactContentCache(directory: directory),
            stream: { _, receive in
                try await source.fetch(key: "fixture", receive: receive)
            }
        )

        for _ in 0..<2 {
            try await loader.stream(
                path: "/tmp/fixture.txt",
                modifiedAt: Date(timeIntervalSince1970: 100),
                size: Int64(bytes.count),
                onChunk: { _ in }
            )
        }

        #expect(await source.fetchCount(for: "fixture") == 2)
    }

    private func stream(
        key: String,
        at seconds: TimeInterval,
        cache: ChatArtifactContentCache,
        source: CountingContentSource
    ) async throws {
        _ = try await cache.stream(
            for: key,
            expectedSize: 3,
            accessedAt: Date(timeIntervalSince1970: seconds),
            fetch: { receive in
                try await source.fetch(key: key, receive: receive)
            },
            receive: { _ in }
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-content-cache-\(UUID().uuidString)", isDirectory: true)
    }
}
