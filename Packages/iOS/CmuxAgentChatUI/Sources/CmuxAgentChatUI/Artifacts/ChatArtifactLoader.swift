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
    /// Whether directory stat results may route into a navigable folder browser.
    public let supportsDirectoryBrowsing: Bool
    /// Authorization and cache namespace for artifact operations.
    public let scope: ChatArtifactLoaderScope

    private let statHandler: @Sendable (_ path: String) async throws -> ChatArtifactStat
    private let fetchHandler: @Sendable (
        _ path: String,
        _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data
    private let streamHandler: @Sendable (
        _ path: String,
        _ onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws -> Void
    private let thumbnailHandler: @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail
    private let listHandler: @Sendable (_ path: String) async throws -> ChatArtifactDirectoryListing
    private let thumbnailCache: ChatArtifactThumbnailCache
    private let contentCache: ChatArtifactContentCache

    /// Creates a closure-backed artifact loader.
    ///
    /// - Parameters:
    ///   - supportsArtifacts: Whether artifact operations are available.
    ///   - supportsDirectoryBrowsing: Whether directory stat results may be listed.
    ///   - scope: Cache and authorization namespace for this loader.
    ///   - cache: Thumbnail cache shared by rows and viewers.
    ///   - contentCache: Full-content cache shared by viewer routes.
    ///   - stat: Metadata operation for an absolute host path.
    ///   - fetch: Whole-file operation retained for image and compatibility callers.
    ///   - stream: Optional structured chunk operation; defaults to one callback
    ///     containing the result of `fetch`.
    ///   - thumbnail: Thumbnail operation for image artifacts.
    ///   - list: Immediate-directory listing operation.
    public init(
        supportsArtifacts: Bool = false,
        supportsDirectoryBrowsing: Bool = false,
        scope: ChatArtifactLoaderScope = .unsupported,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault(),
        stat: @escaping @Sendable (_ path: String) async throws -> ChatArtifactStat = { _ in
            throw ChatArtifactError.unsupported
        },
        fetch: @escaping @Sendable (
            _ path: String,
            _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
        ) async throws -> Data = { _, _ in
            throw ChatArtifactError.unsupported
        },
        stream: (@Sendable (
            _ path: String,
            _ onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
        ) async throws -> Void)? = nil,
        thumbnail: @escaping @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail = { _, _ in
            throw ChatArtifactError.unsupported
        },
        list: @escaping @Sendable (_ path: String) async throws -> ChatArtifactDirectoryListing = { _ in
            throw ChatArtifactError.unsupported
        }
    ) {
        self.supportsArtifacts = supportsArtifacts
        self.supportsDirectoryBrowsing = supportsDirectoryBrowsing
        self.scope = scope
        self.thumbnailCache = cache
        self.contentCache = contentCache
        statHandler = stat
        fetchHandler = fetch
        streamHandler = stream ?? { path, onChunk in
            let data = try await fetch(path, nil)
            try Task.checkCancellation()
            try await onChunk(
                ChatArtifactChunk(
                    data: data,
                    offset: 0,
                    totalSize: Int64(data.count),
                    eof: true
                )
            )
        }
        thumbnailHandler = thumbnail
        listHandler = list
    }

    public init(
        source: any ChatEventSource,
        sessionID: String,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault()
    ) {
        self.init(
            supportsArtifacts: source.supportsArtifacts,
            supportsDirectoryBrowsing: source.supportsArtifactFolders,
            scope: .chat(sessionID: sessionID),
            cache: cache,
            contentCache: contentCache,
            stat: { path in
                try await source.artifactStat(sessionID: sessionID, path: path)
            },
            fetch: { path, progress in
                try await source.artifactFetch(sessionID: sessionID, path: path, progress: progress)
            },
            stream: { path, onChunk in
                try await source.artifactFetch(sessionID: sessionID, path: path, onChunk: onChunk)
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

    /// Creates a terminal-scoped closure-backed artifact loader.
    ///
    /// - Parameters:
    ///   - terminalWorkspaceID: Workspace containing the terminal surface.
    ///   - terminalSurfaceID: Terminal surface authorizing visible paths.
    ///   - supportsArtifacts: Whether terminal artifact operations are available.
    ///   - supportsDirectoryBrowsing: Whether terminal directory listing is available.
    ///   - cache: Thumbnail cache shared by rows and viewers.
    ///   - contentCache: Full-content cache shared by viewer routes.
    ///   - stat: Metadata operation for an absolute host path.
    ///   - fetch: Whole-file compatibility operation.
    ///   - stream: Optional structured chunk operation.
    ///   - thumbnail: Thumbnail operation for image artifacts.
    ///   - list: Immediate-directory listing operation.
    public init(
        terminalWorkspaceID: String,
        terminalSurfaceID: String,
        supportsArtifacts: Bool,
        supportsDirectoryBrowsing: Bool = false,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault(),
        stat: @escaping @Sendable (_ path: String) async throws -> ChatArtifactStat,
        fetch: @escaping @Sendable (
            _ path: String,
            _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
        ) async throws -> Data,
        stream: (@Sendable (
            _ path: String,
            _ onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
        ) async throws -> Void)? = nil,
        thumbnail: @escaping @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail,
        list: @escaping @Sendable (_ path: String) async throws -> ChatArtifactDirectoryListing = { _ in
            throw ChatArtifactError.unsupported
        }
    ) {
        self.init(
            supportsArtifacts: supportsArtifacts,
            supportsDirectoryBrowsing: supportsDirectoryBrowsing,
            scope: .terminal(workspaceID: terminalWorkspaceID, surfaceID: terminalSurfaceID),
            cache: cache,
            contentCache: contentCache,
            stat: stat,
            fetch: fetch,
            stream: stream,
            thumbnail: thumbnail,
            list: list
        )
    }

    public static func unsupported(
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault()
    ) -> ChatArtifactLoader {
        ChatArtifactLoader(cache: cache, contentCache: contentCache)
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

    /// Streams artifact chunks without requiring a contiguous whole-file copy.
    ///
    /// - Parameters:
    ///   - path: Absolute Mac host path.
    ///   - modifiedAt: Stat modification time used to invalidate cached bytes.
    ///   - size: Stat byte size used to validate and invalidate cached bytes.
    ///   - onChunk: Structured callback awaited for each chunk in byte order.
    public func stream(
        path: String,
        modifiedAt: Date? = nil,
        size: Int64? = nil,
        onChunk: @escaping @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        guard scope != .unsupported,
              let key = ChatArtifactContentCache.key(
            scopeKey: scope.cacheNamespace,
            path: path,
            modifiedAt: modifiedAt,
            size: size
        ), let size else {
            try await streamHandler(path, onChunk)
            return
        }
        let handler = streamHandler
        _ = try await contentCache.stream(
            for: key,
            expectedSize: size,
            fetch: { receive in
                try await handler(path, receive)
            },
            receive: onChunk
        )
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
        guard supportsDirectoryBrowsing else {
            throw ChatArtifactError.unsupported
        }
        return try await listHandler(path)
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
