import CmuxAgentChat
import Foundation
import SwiftUI

/// In-memory thumbnail cache shared by artifact rows and sheets.
public actor ChatArtifactThumbnailCache {
    private let cache = NSCache<NSString, CacheEntry>()

    public init() {}

    func thumbnail(for key: String) -> ChatArtifactThumbnail? {
        cache.object(forKey: key as NSString)?.thumbnail
    }

    func insert(_ thumbnail: ChatArtifactThumbnail, for key: String) {
        cache.setObject(CacheEntry(thumbnail: thumbnail), forKey: key as NSString)
    }

    private final class CacheEntry {
        let thumbnail: ChatArtifactThumbnail

        init(thumbnail: ChatArtifactThumbnail) {
            self.thumbnail = thumbnail
        }
    }
}

/// Value-type closure bundle for Mac-hosted artifact operations.
public struct ChatArtifactLoader: Sendable {
    public let supportsArtifacts: Bool

    private let statHandler: @Sendable (_ path: String) async throws -> ChatArtifactStat
    private let fetchHandler: @Sendable (
        _ path: String,
        _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data
    private let thumbnailHandler: @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail
    private let listHandler: @Sendable (_ path: String) async throws -> ChatArtifactDirectoryListing
    private let thumbnailCache: ChatArtifactThumbnailCache
    private let cacheNamespace: String

    public init(
        supportsArtifacts: Bool = false,
        cacheNamespace: String = "unsupported",
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        stat: @escaping @Sendable (_ path: String) async throws -> ChatArtifactStat = { _ in
            throw ChatArtifactError.unsupported
        },
        fetch: @escaping @Sendable (
            _ path: String,
            _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
        ) async throws -> Data = { _, _ in
            throw ChatArtifactError.unsupported
        },
        thumbnail: @escaping @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail = { _, _ in
            throw ChatArtifactError.unsupported
        },
        list: @escaping @Sendable (_ path: String) async throws -> ChatArtifactDirectoryListing = { _ in
            throw ChatArtifactError.unsupported
        }
    ) {
        self.supportsArtifacts = supportsArtifacts
        self.cacheNamespace = cacheNamespace
        self.thumbnailCache = cache
        statHandler = stat
        fetchHandler = fetch
        thumbnailHandler = thumbnail
        listHandler = list
    }

    public init(
        source: any ChatEventSource,
        sessionID: String,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache()
    ) {
        self.init(
            supportsArtifacts: source.supportsArtifacts,
            cacheNamespace: sessionID,
            cache: cache,
            stat: { path in
                try await source.artifactStat(sessionID: sessionID, path: path)
            },
            fetch: { path, progress in
                try await source.artifactFetch(sessionID: sessionID, path: path, progress: progress)
            },
            thumbnail: { path, maxDimension in
                try await source.artifactThumbnail(
                    sessionID: sessionID,
                    path: path,
                    maxDimension: maxDimension
                )
            },
            list: { path in
                try await source.artifactList(sessionID: sessionID, path: path)
            }
        )
    }

    public static func unsupported(cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache()) -> ChatArtifactLoader {
        ChatArtifactLoader(cache: cache)
    }

    public func stat(path: String) async throws -> ChatArtifactStat {
        try await statHandler(path)
    }

    public func fetch(
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> Data {
        try await fetchHandler(path, progress)
    }

    public func thumbnail(path: String, maxDimension: Int) async throws -> ChatArtifactThumbnail {
        let key = thumbnailCacheKey(path: path, maxDimension: maxDimension)
        if let cached = await thumbnailCache.thumbnail(for: key) {
            return cached
        }
        let thumbnail = try await thumbnailHandler(path, maxDimension)
        await thumbnailCache.insert(thumbnail, for: key)
        return thumbnail
    }

    public func list(path: String) async throws -> ChatArtifactDirectoryListing {
        try await listHandler(path)
    }

    private func thumbnailCacheKey(path: String, maxDimension: Int) -> String {
        "\(cacheNamespace)#\(maxDimension)#\(path)"
    }
}

private struct ChatArtifactLoaderEnvironmentKey: EnvironmentKey {
    static let defaultValue = ChatArtifactLoader.unsupported()
}

public extension EnvironmentValues {
    var chatArtifactLoader: ChatArtifactLoader {
        get { self[ChatArtifactLoaderEnvironmentKey.self] }
        set { self[ChatArtifactLoaderEnvironmentKey.self] = newValue }
    }
}
