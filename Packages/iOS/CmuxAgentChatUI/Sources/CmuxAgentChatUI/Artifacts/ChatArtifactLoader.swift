import CmuxAgentChat
import Foundation
import SwiftUI

/// In-memory thumbnail cache shared by artifact rows and sheets.
public actor ChatArtifactThumbnailCache {
    private let cache = NSCache<NSString, CacheEntry>()
    private let diskCache: ChatArtifactThumbnailDiskCache
    private var inFlight: [String: Task<ChatArtifactThumbnail, any Error>] = [:]

    /// Creates a memory cache fronting an injected purgeable disk cache.
    public init(diskCache: ChatArtifactThumbnailDiskCache = .applicationDefault()) {
        self.diskCache = diskCache
    }

    func thumbnail(
        for key: String,
        diskKey: String?,
        fetch: @escaping @Sendable () async throws -> ChatArtifactThumbnail
    ) async throws -> ChatArtifactThumbnail {
        if let cached = cache.object(forKey: key as NSString)?.thumbnail {
            return cached
        }
        if let diskKey, let thumbnail = await diskCache.thumbnail(for: diskKey) {
            cache.setObject(CacheEntry(thumbnail: thumbnail), forKey: key as NSString)
            return thumbnail
        }
        if let pending = inFlight[key] {
            return try await pending.value
        }
        let task = Task { try await fetch() }
        inFlight[key] = task
        do {
            let thumbnail = try await task.value
            inFlight[key] = nil
            cache.setObject(CacheEntry(thumbnail: thumbnail), forKey: key as NSString)
            if let diskKey {
                try? await diskCache.insert(thumbnail, for: diskKey)
            }
            return thumbnail
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private final class CacheEntry {
        let thumbnail: ChatArtifactThumbnail

        init(thumbnail: ChatArtifactThumbnail) {
            self.thumbnail = thumbnail
        }
    }
}

/// Cache and routing scope for Mac-hosted artifact operations.
public enum ChatArtifactLoaderScope: Hashable, Sendable {
    /// Artifacts referenced by one agent-chat session.
    case chat(sessionID: String)
    /// Artifacts currently visible in one terminal surface.
    case terminal(workspaceID: String, surfaceID: String)
    /// Unsupported fixture/default scope.
    case unsupported

    var cacheNamespace: String {
        switch self {
        case .chat(let sessionID):
            return "chat:\(sessionID)"
        case .terminal(let workspaceID, let surfaceID):
            return "terminal:\(workspaceID):\(surfaceID)"
        case .unsupported:
            return "unsupported"
        }
    }
}

/// Value-type closure bundle for Mac-hosted artifact operations.
public struct ChatArtifactLoader: Sendable {
    public let supportsArtifacts: Bool
    public let scope: ChatArtifactLoaderScope

    private let statHandler: @Sendable (_ path: String) async throws -> ChatArtifactStat
    private let fetchHandler: @Sendable (
        _ path: String,
        _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data
    private let thumbnailHandler: @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail
    private let listHandler: @Sendable (_ path: String) async throws -> ChatArtifactDirectoryListing
    private let thumbnailCache: ChatArtifactThumbnailCache

    public init(
        supportsArtifacts: Bool = false,
        scope: ChatArtifactLoaderScope = .unsupported,
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
        self.scope = scope
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
            scope: .chat(sessionID: sessionID),
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

    public init(
        terminalWorkspaceID: String,
        terminalSurfaceID: String,
        supportsArtifacts: Bool,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        stat: @escaping @Sendable (_ path: String) async throws -> ChatArtifactStat,
        fetch: @escaping @Sendable (
            _ path: String,
            _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
        ) async throws -> Data,
        thumbnail: @escaping @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail
    ) {
        self.init(
            supportsArtifacts: supportsArtifacts,
            scope: .terminal(workspaceID: terminalWorkspaceID, surfaceID: terminalSurfaceID),
            cache: cache,
            stat: stat,
            fetch: fetch,
            thumbnail: thumbnail,
            list: { _ in throw ChatArtifactError.unsupported }
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

    public func thumbnail(
        path: String,
        maxDimension: Int,
        modifiedAt: Date? = nil,
        size: Int64? = nil
    ) async throws -> ChatArtifactThumbnail {
        let key = thumbnailCacheKey(
            path: path,
            maxDimension: maxDimension,
            modifiedAt: modifiedAt,
            size: size
        )
        let diskKey = ChatArtifactThumbnailDiskCache.key(
            scopeKey: scope.cacheNamespace,
            path: path,
            modifiedAt: modifiedAt,
            size: size,
            maxDimension: maxDimension
        )
        let handler = thumbnailHandler
        return try await thumbnailCache.thumbnail(for: key, diskKey: diskKey) {
            try await handler(path, maxDimension)
        }
    }

    public func list(path: String) async throws -> ChatArtifactDirectoryListing {
        try await listHandler(path)
    }

    private func thumbnailCacheKey(
        path: String,
        maxDimension: Int,
        modifiedAt: Date?,
        size: Int64?
    ) -> String {
        if let diskKey = ChatArtifactThumbnailDiskCache.key(
            scopeKey: scope.cacheNamespace,
            path: path,
            modifiedAt: modifiedAt,
            size: size,
            maxDimension: maxDimension
        ) {
            return diskKey
        }
        return "\(scope.cacheNamespace)#\(maxDimension)#\(path)"
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
