public import CmuxAgentChat
public import Foundation

/// Builds and caches the transcript-derived artifact scope for chat sessions.
public actor AgentChatArtifactIndex {
    public init() {}

    public struct Snapshot: Sendable {
        public let referencedPaths: Set<String>
        public let artifacts: [ChatArtifactIndexedReference]
        public let generation: String

        public init(
            referencedPaths: Set<String>,
            artifacts: [ChatArtifactIndexedReference],
            generation: String
        ) {
            self.referencedPaths = referencedPaths
            self.artifacts = artifacts
            self.generation = generation
        }
    }

    public enum Operation: Sendable {
        case file
        case list
    }

    public enum CanonicalPathResult: Sendable {
        case success(String)
        case canonicalizationFailed
        case notInSet
    }

    private struct CacheKey: Sendable, Equatable {
        let transcriptPath: String
        let workingDirectory: String?
        let fileSize: UInt64
        let modifiedAt: Date

        var generation: String {
            "\(fileSize)-\(Int64(modifiedAt.timeIntervalSince1970 * 1_000_000))"
        }
    }

    private struct CacheEntry: Sendable {
        let key: CacheKey
        let snapshot: Snapshot
    }

    /// How much of a transcript's tail one snapshot reads. Paths referenced
    /// only before this window leave the scope, which fails closed.
    static let scanLimits = TranscriptTailLimits(
        maxLines: 200_000,
        maxBytes: 256 * 1024 * 1024,
        maxRecordBytes: 8 * 1024 * 1024
    )

    private var cacheBySessionID = ChatArtifactLRUCache<String, CacheEntry>(capacity: 8)

    public func snapshot(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?
    ) async throws -> Snapshot {
        let key = try Self.cacheKey(transcriptPath: transcriptPath, workingDirectory: workingDirectory)
        if let cached = cacheBySessionID.value(forKey: sessionID), cached.key == key {
            return cached.snapshot
        }
        // Off the actor, so a slow transcript doesn't hold up other sessions'
        // lookups, and cancelled along with the request that asked for it.
        let build = Task.detached(priority: .utility) {
            try Self.buildSnapshot(
                agentKind: agentKind,
                transcriptPath: transcriptPath,
                workingDirectory: workingDirectory,
                generation: key.generation
            )
        }
        let snapshot = try await withTaskCancellationHandler {
            try await build.value
        } onCancel: {
            build.cancel()
        }
        cacheBySessionID.insert(CacheEntry(key: key, snapshot: snapshot), forKey: sessionID)
        return snapshot
    }

    public func canonicalPath(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        requestedPath: String,
        operation: Operation,
        directoryAccessMode: ChatArtifactScope.DirectoryAccessMode
    ) async throws -> CanonicalPathResult {
        let snapshot = try await snapshot(
            sessionID: sessionID,
            agentKind: agentKind,
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory
        )
        let resolver = ChatArtifactScope.FoundationResolver()
        guard ChatArtifactScope.canonicalizedPath(requestedPath, resolver: resolver) != nil else {
            return .canonicalizationFailed
        }
        let canonicalPath: String?
        let scope = ChatArtifactScope(
            referencedPaths: snapshot.referencedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        switch operation {
        case .file:
            canonicalPath = scope.canonicalFilePath(for: requestedPath)
        case .list:
            canonicalPath = scope.canonicalDirectoryListPath(for: requestedPath)
        }
        return canonicalPath.map(CanonicalPathResult.success) ?? .notInSet
    }

    private static func cacheKey(transcriptPath: String, workingDirectory: String?) throws -> CacheKey {
        let attributes = try FileManager.default.attributesOfItem(atPath: transcriptPath)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return CacheKey(
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory,
            fileSize: size,
            modifiedAt: modifiedAt
        )
    }

    private static func buildSnapshot(
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        generation: String
    ) throws -> Snapshot {
        guard let reader = TranscriptTailReader(path: transcriptPath) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let limits = scanLimits
        let window = try reader.scan(limits: limits)
        // A last line with no newline yet still counts as a line here.
        let lines = reader.lines(
            in: window.lineRanges + [window.trailingFragment],
            maxRecordBytes: limits.maxRecordBytes
        )
        let parseResult: ChatTranscriptParseResult
        switch agentKind {
        case .codex:
            parseResult = CodexTranscriptParser().parse(lines: lines, startingSeq: window.firstLine)
        case .claude, .other:
            parseResult = ClaudeTranscriptParser().parse(lines: lines, startingSeq: window.firstLine)
        }
        // The line sequence ends early on cancellation; don't cache a partial scope.
        try Task.checkCancellation()
        let artifacts = ChatArtifactIndexedReference.derive(
            from: parseResult.messages,
            supplementalReferences: parseResult.artifactReferences,
            workingDirectory: workingDirectory
        )
        let referencedPaths = Set(artifacts.map(\.path))
        return Snapshot(
            referencedPaths: referencedPaths,
            artifacts: artifacts,
            generation: generation
        )
    }
}
