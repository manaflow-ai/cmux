import CMUXMobileCore
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
    /// The single file currently displayed by one file-backed panel surface.
    case panel(workspaceID: String, surfaceID: String)
    /// One changed-file revision in a workspace changes snapshot.
    case workspaceChanges(workspaceID: String, revision: String, path: String)
    /// Unsupported fixture/default scope.
    case unsupported

    var cacheNamespace: String {
        switch self {
        case .chat(let sessionID):
            return "chat:\(sessionID)"
        case .terminal(let workspaceID, let surfaceID):
            return "terminal:\(workspaceID):\(surfaceID)"
        case .panel(let workspaceID, let surfaceID):
            return "panel:\(workspaceID):\(surfaceID)"
        case .workspaceChanges(let workspaceID, let revision, let path):
            return "workspace-changes:\(workspaceID):\(revision):\(path)"
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
    /// Whether chat-scoped files can be persisted into project Artifacts.
    public let supportsArtifactSave: Bool
    /// Authorization and cache namespace for artifact operations.
    public let scope: ChatArtifactLoaderScope
    /// Identity of the immutable event source captured by this loader.
    ///
    /// A changed value means an owning view has adopted a different RPC client
    /// and must restart source-backed artifact work. Fixture and terminal
    /// loaders leave this `nil` because they do not participate in the mobile
    /// client handoff lifecycle.
    public let sourceIdentity: String?

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
    private let saveHandler: @Sendable (_ path: String) async throws -> ChatArtifactSaveResult
    private let thumbnailCache: ChatArtifactThumbnailCache
    private let contentCache: ChatArtifactContentCache
    private let diagnosticLog: DiagnosticLog?
    private let diagnosticCorrelationID: String?

    /// Creates a closure-backed artifact loader.
    ///
    /// - Parameters:
    ///   - supportsArtifacts: Whether artifact operations are available.
    ///   - supportsDirectoryBrowsing: Whether directory stat results may be listed.
    ///   - supportsArtifactSave: Whether chat-scoped files can be persisted into project Artifacts.
    ///   - scope: Cache and authorization namespace for this loader.
    ///   - sourceIdentity: Identity of the immutable event source captured by this loader.
    ///   - cache: Thumbnail cache shared by rows and viewers.
    ///   - contentCache: Full-content cache shared by viewer routes.
    ///   - stat: Metadata operation for an absolute host path.
    ///   - fetch: Whole-file operation retained for image and compatibility callers.
    ///   - stream: Optional structured chunk operation; defaults to one callback
    ///     containing the result of `fetch`.
    ///   - thumbnail: Thumbnail operation for image artifacts.
    ///   - list: Immediate-directory listing operation.
    ///   - save: Project-local persistence operation.
    public init(
        supportsArtifacts: Bool = false,
        supportsDirectoryBrowsing: Bool = false,
        supportsArtifactSave: Bool = false,
        scope: ChatArtifactLoaderScope = .unsupported,
        sourceIdentity: String? = nil,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault(),
        diagnosticLog: DiagnosticLog? = nil,
        diagnosticCorrelationID: String? = nil,
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
        },
        save: @escaping @Sendable (_ path: String) async throws -> ChatArtifactSaveResult = { _ in
            throw ChatArtifactError.unsupported
        }
    ) {
        self.supportsArtifacts = supportsArtifacts
        self.supportsDirectoryBrowsing = supportsDirectoryBrowsing
        self.supportsArtifactSave = supportsArtifactSave
        self.scope = scope
        self.sourceIdentity = sourceIdentity
        self.thumbnailCache = cache
        self.contentCache = contentCache
        self.diagnosticLog = diagnosticLog
        self.diagnosticCorrelationID = diagnosticCorrelationID ?? scope.diagnosticCorrelationID
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
        saveHandler = save
    }

    /// Creates an artifact loader backed by a chat event source.
    ///
    /// - Parameters:
    ///   - source: Event source that owns the Mac-side artifact operations.
    ///   - sessionID: Chat session authorizing the artifact paths.
    ///   - sourceIdentity: Optional identity for the immutable source generation.
    ///   - cache: Thumbnail cache shared by rows and viewers.
    ///   - contentCache: Full-content cache shared by viewer routes.
    ///   - diagnosticLog: Optional application diagnostic sink.
    public init(
        source: any ChatEventSource,
        sessionID: String,
        sourceIdentity: String? = nil,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault(),
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.init(
            supportsArtifacts: source.supportsArtifacts,
            supportsDirectoryBrowsing: source.supportsArtifactFolders,
            supportsArtifactSave: source.supportsArtifactSave,
            scope: .chat(sessionID: sessionID),
            sourceIdentity: sourceIdentity,
            cache: cache,
            contentCache: contentCache,
            diagnosticLog: diagnosticLog,
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
            },
            save: { path in
                try await source.artifactSave(sessionID: sessionID, path: path)
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
        diagnosticLog: DiagnosticLog? = nil,
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
            diagnosticLog: diagnosticLog,
            stat: stat,
            fetch: fetch,
            stream: stream,
            thumbnail: thumbnail,
            list: list
        )
    }

    /// Creates a panel-scoped closure-backed artifact loader.
    ///
    /// Panel authorization is a one-file allowlist, so directory browsing is
    /// always disabled and cannot be enabled by a caller.
    ///
    /// - Parameters:
    ///   - panelWorkspaceID: Workspace containing the file-backed panel.
    ///   - panelSurfaceID: Panel surface authorizing its displayed file.
    ///   - supportsArtifacts: Whether the connected Mac advertises panel reads.
    ///   - cache: Thumbnail cache shared by rows and viewers.
    ///   - contentCache: Full-content cache shared by viewer routes.
    ///   - stat: Metadata operation for the panel's file.
    ///   - fetch: Whole-file compatibility operation.
    ///   - stream: Optional structured chunk operation.
    ///   - thumbnail: Thumbnail operation for the panel's file.
    public init(
        panelWorkspaceID: String,
        panelSurfaceID: String,
        supportsArtifacts: Bool,
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault(),
        diagnosticLog: DiagnosticLog? = nil,
        stat: @escaping @Sendable (_ path: String) async throws -> ChatArtifactStat,
        fetch: @escaping @Sendable (
            _ path: String,
            _ progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
        ) async throws -> Data,
        stream: (@Sendable (
            _ path: String,
            _ onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
        ) async throws -> Void)? = nil,
        thumbnail: @escaping @Sendable (_ path: String, _ maxDimension: Int) async throws -> ChatArtifactThumbnail
    ) {
        self.init(
            supportsArtifacts: supportsArtifacts,
            supportsDirectoryBrowsing: false,
            scope: .panel(workspaceID: panelWorkspaceID, surfaceID: panelSurfaceID),
            cache: cache,
            contentCache: contentCache,
            diagnosticLog: diagnosticLog,
            stat: stat,
            fetch: fetch,
            stream: stream,
            thumbnail: thumbnail
        )
    }

    /// Creates a loader that fails artifact operations as unsupported.
    ///
    /// - Parameters:
    ///   - cache: Thumbnail cache shared by rows and viewers.
    ///   - contentCache: Full-content cache shared by viewer routes.
    ///   - diagnosticLog: Optional application diagnostic sink.
    ///   - sourceIdentity: Optional source generation to use for view reload identity.
    public static func unsupported(
        cache: ChatArtifactThumbnailCache = ChatArtifactThumbnailCache(),
        contentCache: ChatArtifactContentCache = .applicationDefault(),
        diagnosticLog: DiagnosticLog? = nil,
        sourceIdentity: String? = nil
    ) -> ChatArtifactLoader {
        ChatArtifactLoader(
            sourceIdentity: sourceIdentity,
            cache: cache,
            contentCache: contentCache,
            diagnosticLog: diagnosticLog
        )
    }

    /// Records a viewer-owned artifact action without retaining its path.
    public func recordDiagnostic(
        _ kind: DiagnosticAppEventKind,
        failure: DiagnosticFailureKind? = nil,
        count: Int? = nil
    ) {
        diagnosticLog?.recordAppEvent(
            kind,
            correlationID: diagnosticCorrelationID,
            failure: failure,
            count: count
        )
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
        let validation = ChatArtifactStreamValidation(expectedSize: size)
        let validatedReceive: @Sendable (ChatArtifactChunk) async throws -> Void = { chunk in
            try await validation.receive(chunk)
            try await onChunk(chunk)
        }
        guard scope != .unsupported,
            let key = ChatArtifactContentCache.key(
                scopeKey: cacheScopeNamespace,
                path: path,
                modifiedAt: modifiedAt,
                size: size
        ), let size else {
            try await streamHandler(path, validatedReceive)
            try await validation.finish()
            return
        }
        let handler = streamHandler
        let wasCacheHit = try await contentCache.stream(
            for: key,
            expectedSize: size,
            fetch: { receive in
                try await handler(path, receive)
            },
            receive: validatedReceive
        )
        try await validation.finish()
        if wasCacheHit {
            recordDiagnostic(.artifactCacheHit, count: Int(clamping: size))
        }
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
            scopeKey: cacheScopeNamespace,
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

    /// Persists a chat-authorized file into the session project's artifact store.
    ///
    /// - Parameter path: Absolute host path authorized by the chat artifact scope.
    /// - Returns: Stable project-local path and prompt reference.
    public func save(path: String) async throws -> ChatArtifactSaveResult {
        guard supportsArtifactSave else {
            throw ChatArtifactError.unsupported
        }
        return try await saveHandler(path)
    }

    private func thumbnailCacheKey(
        path: String,
        maxDimension: Int,
        modifiedAt: Date?,
        size: Int64?
    ) -> String {
        if let diskKey = ChatArtifactThumbnailDiskCache.key(
            scopeKey: cacheScopeNamespace,
            path: path,
            modifiedAt: modifiedAt,
            size: size,
            maxDimension: maxDimension
        ) {
            return diskKey
        }
        return "\(cacheScopeNamespace)#\(maxDimension)#\(path)"
    }

    /// Cache namespace for one immutable source generation.
    ///
    /// A reconnect can expose the same session and host path through a new Mac
    /// RPC client while the old cache still contains bytes for that path. Keep
    /// each source generation in a separate namespace so a restarted load
    /// cannot replay data authorized by the retired connection.
    private var cacheScopeNamespace: String {
        guard let sourceIdentity else { return scope.cacheNamespace }
        return "\(scope.cacheNamespace)#source-generation:\(sourceIdentity)"
    }
}

private extension ChatArtifactLoaderScope {
    var diagnosticCorrelationID: String? {
        switch self {
        case .chat(let sessionID):
            sessionID
        case .terminal(_, let surfaceID):
            surfaceID
        case .panel(_, let surfaceID):
            surfaceID
        case .workspaceChanges(let workspaceID, _, _):
            workspaceID
        case .unsupported:
            nil
        }
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
