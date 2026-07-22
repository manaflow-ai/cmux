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
        let transcriptExtent: UInt64

        init(
            referencedPaths: Set<String>,
            artifacts: [ChatArtifactIndexedReference],
            generation: String,
            revision: UInt64,
            transcriptLineage: String = "",
            transcriptExtent: UInt64? = nil
        ) {
            self.referencedPaths = referencedPaths
            self.artifacts = artifacts
            self.generation = generation
            self.revision = revision
            self.transcriptLineage = transcriptLineage
            self.transcriptExtent = transcriptExtent
                ?? UInt64(max(0, artifacts.map(\.lastReferencedSeq).max() ?? 0))
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
        let maximumFileBytes: UInt64

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
        let previous = cacheBySessionID.value(forKey: sessionID)
        let extendsPreviousTranscript = previous.map {
            $0.key.transcriptLineage == key.transcriptLineage
                && $0.key.transcriptPath == key.transcriptPath
                && $0.key.workingDirectory == key.workingDirectory
                && $0.key.maximumFileBytes == key.maximumFileBytes
                && $0.key.fileSize < key.fileSize
        } ?? false
        let slice = try AgentChatTranscriptReader().read(
            handle: opened.handle,
            fileSize: key.fileSize,
            maximumBytes: key.maximumFileBytes
        )
        nextSnapshotRevision &+= 1
        let snapshot = try Self.buildSnapshot(
            agentKind: agentKind,
            slice: slice,
            workingDirectory: workingDirectory,
            generation: key.generation,
            revision: nextSnapshotRevision,
            transcriptLineage: key.transcriptLineage,
            previousArtifacts: extendsPreviousTranscript ? previous?.snapshot.artifacts ?? [] : []
        )
        cacheBySessionID.insert(
            CacheEntry(
                key: key,
                snapshot: snapshot
            ),
            forKey: sessionID
        )
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
        let modifiedAt = Date(
            timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
                + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let key = CacheKey(
            transcriptPath: path,
            workingDirectory: workingDirectory,
            fileSize: size,
            modifiedAt: modifiedAt,
            transcriptLineage: "\(path):\(status.st_dev):\(status.st_ino)",
            maximumFileBytes: maximumFileBytes
        )
        return (key, handle)
    }

    private static func buildSnapshot(
        agentKind: ChatAgentKind,
        slice: AgentChatTranscriptSlice,
        workingDirectory: String?,
        generation: String,
        revision: UInt64,
        transcriptLineage: String,
        previousArtifacts: [ChatArtifactIndexedReference]
    ) throws -> Snapshot {
        let text = String(decoding: slice.data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parseResult: ChatTranscriptParseResult
        switch agentKind {
        case .codex:
            parseResult = CodexTranscriptParser().parse(
                lines: lines,
                startingSeq: 0
            )
        case .claude, .other:
            parseResult = ClaudeTranscriptParser().parse(
                lines: lines,
                startingSeq: 0
            )
        }
        let relativeArtifacts = ChatArtifactIndexedReference.derive(
            from: parseResult.messages,
            supplementalReferences: parseResult.artifactReferences,
            workingDirectory: workingDirectory
        )
        let currentArtifacts = relativeArtifacts.compactMap { artifact -> ChatArtifactIndexedReference? in
            guard slice.lineStartOffsets.indices.contains(artifact.lastReferencedSeq),
                  let absoluteSequence = Int(
                    exactly: slice.lineStartOffsets[artifact.lastReferencedSeq]
                  ) else {
                return nil
            }
            return ChatArtifactIndexedReference(
                path: artifact.path,
                provenance: artifact.provenance,
                lastReferencedSeq: absoluteSequence
            )
        }
        let artifacts = mergedArtifacts(previousArtifacts, currentArtifacts)
        let referencedPaths = Set(artifacts.map(\.path))
        return Snapshot(
            referencedPaths: referencedPaths,
            artifacts: artifacts,
            generation: generation,
            revision: revision,
            transcriptLineage: transcriptLineage,
            transcriptExtent: slice.transcriptExtent
        )
    }

    private static func mergedArtifacts(
        _ previous: [ChatArtifactIndexedReference],
        _ current: [ChatArtifactIndexedReference]
    ) -> [ChatArtifactIndexedReference] {
        var artifacts = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
        for artifact in current {
            let existing = artifacts[artifact.path]
            artifacts[artifact.path] = ChatArtifactIndexedReference(
                path: artifact.path,
                provenance: higherPrecedence(existing?.provenance, artifact.provenance),
                lastReferencedSeq: max(
                    existing?.lastReferencedSeq ?? Int.min,
                    artifact.lastReferencedSeq
                )
            )
        }
        return Array(artifacts.values)
    }

    private static func higherPrecedence(
        _ lhs: ChatArtifactProvenance?,
        _ rhs: ChatArtifactProvenance
    ) -> ChatArtifactProvenance {
        guard let lhs else { return rhs }
        let rank: (ChatArtifactProvenance) -> Int = {
            switch $0 {
            case .created: 0
            case .attached: 1
            case .referenced: 2
            }
        }
        return rank(lhs) <= rank(rhs) ? lhs : rhs
    }
}
