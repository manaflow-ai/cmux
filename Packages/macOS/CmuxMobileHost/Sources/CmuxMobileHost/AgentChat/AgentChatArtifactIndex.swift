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

    struct CacheKey: Sendable, Equatable {
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

    /// What must match for two requests to share a build.
    struct BuildIdentity: Sendable, Hashable {
        let sessionID: String
        let transcriptPath: String
        let workingDirectory: String?
    }

    /// A snapshot being built, shared by every request with the same identity.
    struct InFlightBuild: Sendable {
        let id = UUID()
        let key: CacheKey
        let task: Task<Snapshot, any Error>
        var waiterCount = 0
    }

    /// How much of a transcript's tail one snapshot reads. Paths referenced
    /// only before this window leave the scope, which fails closed.
    static let scanLimits = TranscriptTailLimits(
        maxLines: 200_000,
        maxBytes: 256 * 1024 * 1024,
        maxRecordBytes: 8 * 1024 * 1024
    )

    private var cacheBySessionID = ChatArtifactLRUCache<String, CacheEntry>(capacity: 8)
    private(set) var builds: [BuildIdentity: InFlightBuild] = [:]
    /// Builds started since creation; concurrent misses must share one.
    private(set) var startedBuildCount = 0

    public func snapshot(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?
    ) async throws -> Snapshot {
        // Builds are shared per session, path and directory, so scope never
        // crosses transcripts. After one wait, the build in flight read the file
        // after this request arrived and answers it even if the file grew again,
        // which stops a transcript growing during every build from holding a
        // request forever.
        let identity = BuildIdentity(
            sessionID: sessionID,
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory
        )
        var mayJoinAnyBuild = false
        while true {
            let key = try Self.cacheKey(transcriptPath: transcriptPath, workingDirectory: workingDirectory)
            if let cached = cacheBySessionID.value(forKey: sessionID), cached.key == key {
                return cached.snapshot
            }
            if let build = builds[identity] {
                if build.key == key || mayJoinAnyBuild {
                    return try await join(buildID: build.id, identity: identity)
                }
                // Older than this request: wait for it rather than scan alongside it.
                _ = try? await join(buildID: build.id, identity: identity)
                try Task.checkCancellation()
                mayJoinAnyBuild = true
                continue
            }
            // Off the actor, so a slow transcript doesn't hold up other sessions.
            let task = Task.detached(priority: .utility) {
                try Self.buildSnapshot(
                    agentKind: agentKind,
                    transcriptPath: transcriptPath,
                    workingDirectory: workingDirectory,
                    generation: key.generation
                )
            }
            let build = InFlightBuild(key: key, task: task)
            builds[identity] = build
            startedBuildCount += 1
            return try await join(buildID: build.id, identity: identity)
        }
    }

    /// Waits for a session's build. A cancelled waiter stays until the build
    /// ends unless it is the last one, whose departure cancels the build.
    private func join(buildID: UUID, identity: BuildIdentity) async throws -> Snapshot {
        guard var build = builds[identity], build.id == buildID else {
            throw CancellationError()
        }
        build.waiterCount += 1
        builds[identity] = build
        let task = build.task
        let key = build.key
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            Task { await self.leave(buildID: buildID, identity: identity) }
        }
        // The first waiter to resume publishes the result for later requests.
        if builds[identity]?.id == buildID {
            builds[identity] = nil
            if case .success(let snapshot) = result {
                cacheBySessionID.insert(CacheEntry(key: key, snapshot: snapshot), forKey: identity.sessionID)
            }
        }
        return try result.get()
    }

    private func leave(buildID: UUID, identity: BuildIdentity) {
        guard var build = builds[identity], build.id == buildID else { return }
        build.waiterCount -= 1
        guard build.waiterCount == 0 else {
            builds[identity] = build
            return
        }
        // Later requests start fresh instead of joining a cancelled build.
        builds[identity] = nil
        build.task.cancel()
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
