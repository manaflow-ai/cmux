import CmuxAgentChat
import Darwin
import Foundation

/// Builds and caches the transcript-derived artifact scope for chat sessions.
actor AgentChatArtifactIndex {
    static let hardMaximumTranscriptBytes: UInt64 = 128 * 1024 * 1024

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
        try Task.checkCancellation()
        let byteLimit = min(maximumFileBytes ?? Self.hardMaximumTranscriptBytes,
                            Self.hardMaximumTranscriptBytes)
        let opened = try Self.openTranscript(
            path: transcriptPath,
            workingDirectory: workingDirectory,
            maximumFileBytes: byteLimit
        )
        defer { try? opened.handle.close() }
        let key = opened.key
        if let cached = cacheBySessionID.value(forKey: sessionID), cached.key == key {
            return cached.snapshot
        }
        let data = try Self.readTranscript(opened.handle, byteCount: key.fileSize)
        nextSnapshotRevision &+= 1
        let snapshot = try Self.buildSnapshot(
            agentKind: agentKind,
            data: data,
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

    private static func openTranscript(
        path: String,
        workingDirectory: String?,
        maximumFileBytes: UInt64
    ) throws -> (key: CacheKey, handle: FileHandle) {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            try? handle.close()
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        let size = UInt64(status.st_size)
        guard size <= maximumFileBytes else {
            try? handle.close()
            throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: path])
        }
        let modifiedAt = Date(
            timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
                + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let key = CacheKey(
            transcriptPath: path,
            workingDirectory: workingDirectory,
            fileSize: size,
            modifiedAt: modifiedAt,
            transcriptLineage: "\(path):\(status.st_dev):\(status.st_ino)"
        )
        return (key, handle)
    }

    private static func readTranscript(_ handle: FileHandle, byteCount: UInt64) throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(byteCount))
        var remaining = Int(byteCount)
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            remaining -= chunk.count
        }
        return data
    }

    private static func buildSnapshot(
        agentKind: ChatAgentKind,
        data: Data,
        workingDirectory: String?,
        generation: String,
        revision: UInt64,
        transcriptLineage: String
    ) throws -> Snapshot {
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
