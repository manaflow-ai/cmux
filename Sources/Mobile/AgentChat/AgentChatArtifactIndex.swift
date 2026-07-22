import CmuxAgentChat
import Foundation

/// Builds and caches the transcript-derived artifact scope for chat sessions.
actor AgentChatArtifactIndex {
    struct Snapshot: Sendable {
        let referencedPaths: Set<String>
        let artifacts: [ChatArtifactIndexedReference]
        let generation: String
        let revision: UInt64
        let transcriptLineage: String
        let lineCount: Int

        init(
            referencedPaths: Set<String>,
            artifacts: [ChatArtifactIndexedReference],
            generation: String,
            revision: UInt64,
            transcriptLineage: String = "",
            lineCount: Int? = nil
        ) {
            self.referencedPaths = referencedPaths
            self.artifacts = artifacts
            self.generation = generation
            self.revision = revision
            self.transcriptLineage = transcriptLineage
            self.lineCount = lineCount ?? (artifacts.map(\.lastReferencedSeq).max().map { $0 + 1 } ?? 0)
        }
    }

    enum Operation: Sendable {
        case file
        case list
    }

    enum CanonicalPathResult: Sendable {
        case success(String)
        case canonicalizationFailed
        case notInSet
    }

    private struct CacheKey: Sendable, Equatable {
        let transcriptPath: String
        let workingDirectory: String?
        let fileSize: UInt64
        let modifiedAt: Date
        let transcriptLineage: String

        var generation: String {
            "\(fileSize)-\(Int64(modifiedAt.timeIntervalSince1970 * 1_000_000))"
        }
    }

    private struct CacheEntry: Sendable {
        let key: CacheKey
        let snapshot: Snapshot
    }

    private var cacheBySessionID = ChatArtifactLRUCache<String, CacheEntry>(capacity: 8)
    private var nextSnapshotRevision: UInt64 = 0

    func snapshot(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        maximumFileBytes: UInt64? = nil
    ) async throws -> Snapshot {
        let key = try Self.cacheKey(transcriptPath: transcriptPath, workingDirectory: workingDirectory)
        if let maximumFileBytes, key.fileSize > maximumFileBytes {
            throw CocoaError(
                .fileReadTooLarge,
                userInfo: [
                    NSFilePathErrorKey: transcriptPath,
                ]
            )
        }
        if let cached = cacheBySessionID.value(forKey: sessionID), cached.key == key {
            return cached.snapshot
        }
        nextSnapshotRevision &+= 1
        let snapshot = try Self.buildSnapshot(
            agentKind: agentKind,
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory,
            generation: key.generation,
            revision: nextSnapshotRevision,
            transcriptLineage: key.transcriptLineage
        )
        cacheBySessionID.insert(CacheEntry(key: key, snapshot: snapshot), forKey: sessionID)
        return snapshot
    }

    func canonicalPath(
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
        let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return CacheKey(
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory,
            fileSize: size,
            modifiedAt: modifiedAt,
            transcriptLineage: "\(transcriptPath):\(systemNumber):\(fileNumber)"
        )
    }

    private static func buildSnapshot(
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        generation: String,
        revision: UInt64,
        transcriptLineage: String
    ) throws -> Snapshot {
        let data = try Data(contentsOf: URL(fileURLWithPath: transcriptPath), options: .mappedIfSafe)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parseResult: ChatTranscriptParseResult
        switch agentKind {
        case .codex:
            parseResult = CodexTranscriptParser().parse(lines: lines, startingSeq: 0)
        case .claude, .other:
            parseResult = ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0)
        }
        let artifacts = ChatArtifactIndexedReference.derive(
            from: parseResult.messages,
            supplementalReferences: parseResult.artifactReferences,
            workingDirectory: workingDirectory
        )
        let referencedPaths = Set(artifacts.map(\.path))
        return Snapshot(
            referencedPaths: referencedPaths,
            artifacts: artifacts,
            generation: generation,
            revision: revision,
            transcriptLineage: transcriptLineage,
            lineCount: lines.count
        )
    }
}
