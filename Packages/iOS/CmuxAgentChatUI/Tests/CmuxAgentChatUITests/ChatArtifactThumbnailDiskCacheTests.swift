import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxAgentChatUI

@Suite("Chat artifact thumbnail disk cache")
struct ChatArtifactThumbnailDiskCacheTests {
    @Test("key derivation includes scope, metadata, and dimensions")
    func keyDerivation() throws {
        let first = try #require(ChatArtifactThumbnailDiskCache.key(
            scopeKey: "chat:one",
            path: "/tmp/image.png",
            modifiedAt: Date(timeIntervalSince1970: 10),
            size: 20,
            maxDimension: 256
        ))
        let same = try #require(ChatArtifactThumbnailDiskCache.key(
            scopeKey: "chat:one",
            path: "/tmp/image.png",
            modifiedAt: Date(timeIntervalSince1970: 10),
            size: 20,
            maxDimension: 256
        ))
        let changedMtime = try #require(ChatArtifactThumbnailDiskCache.key(
            scopeKey: "chat:one",
            path: "/tmp/image.png",
            modifiedAt: Date(timeIntervalSince1970: 11),
            size: 20,
            maxDimension: 256
        ))
        #expect(first == same)
        #expect(first != changedMtime)
        #expect(ChatArtifactThumbnailDiskCache.key(
            scopeKey: "chat:one",
            path: "/tmp/image.png",
            modifiedAt: nil,
            size: 20,
            maxDimension: 256
        ) == nil)
    }

    @Test("insert over cap evicts the least recently used thumbnail and hits refresh recency")
    func lruEvictionAndHitRecency() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let thumbnail = ChatArtifactThumbnail(
            data: Data(repeating: 7, count: 128),
            pixelWidth: 32,
            pixelHeight: 32
        )
        let encodedSize = try JSONEncoder().encode(thumbnail).count
        let cache = ChatArtifactThumbnailDiskCache(
            directory: directory,
            maxBytes: Int64(encodedSize * 2 + 1)
        )
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        let t4 = Date(timeIntervalSince1970: 4_000)
        try await cache.insert(thumbnail, for: "a", accessedAt: t1)
        try await cache.insert(thumbnail, for: "b", accessedAt: t2)
        #expect(await cache.thumbnail(for: "a", accessedAt: t3) == thumbnail)
        try await cache.insert(thumbnail, for: "c", accessedAt: t4)

        #expect(await cache.thumbnail(for: "a") == thumbnail)
        #expect(await cache.thumbnail(for: "b") == nil)
        #expect(await cache.thumbnail(for: "c") == thumbnail)
    }

    @Test("mtime key change is a disk miss")
    func mtimeInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatArtifactThumbnailDiskCache(directory: directory, maxBytes: 1_024 * 1_024)
        let oldKey = try #require(ChatArtifactThumbnailDiskCache.key(
            scopeKey: "chat:session",
            path: "/tmp/image.png",
            modifiedAt: Date(timeIntervalSince1970: 1),
            size: 3,
            maxDimension: 256
        ))
        let newKey = try #require(ChatArtifactThumbnailDiskCache.key(
            scopeKey: "chat:session",
            path: "/tmp/image.png",
            modifiedAt: Date(timeIntervalSince1970: 2),
            size: 3,
            maxDimension: 256
        ))
        let thumbnail = ChatArtifactThumbnail(data: Data([1, 2, 3]), pixelWidth: 1, pixelHeight: 1)
        try await cache.insert(thumbnail, for: oldKey)
        #expect(await cache.thumbnail(for: oldKey) == thumbnail)
        #expect(await cache.thumbnail(for: newKey) == nil)
    }
}
