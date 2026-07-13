import CmuxAgentChat
import Foundation

/// Builds and caches the transcript-derived artifact scope for chat sessions.
actor AgentChatArtifactIndex {
    struct Snapshot: Sendable {
        let referencedPaths: Set<String>
        let scope: ChatArtifactScope
        let artifacts: [ChatArtifactIndexedReference]
        let generation: String
    }

    enum Operation: Sendable {
        case file
        case list
    }

    private struct CacheKey: Sendable, Equatable {
        let transcriptPath: String
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

    private var cacheBySessionID: [String: CacheEntry] = [:]

    func snapshot(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String
    ) async throws -> Snapshot {
        let key = try Self.cacheKey(transcriptPath: transcriptPath)
        if let cached = cacheBySessionID[sessionID], cached.key == key {
            return cached.snapshot
        }
        let snapshot = try Self.buildSnapshot(
            agentKind: agentKind,
            transcriptPath: transcriptPath,
            generation: key.generation
        )
        cacheBySessionID[sessionID] = CacheEntry(key: key, snapshot: snapshot)
        return snapshot
    }

    func canonicalPath(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        requestedPath: String,
        operation: Operation
    ) async throws -> String? {
        let snapshot = try await snapshot(
            sessionID: sessionID,
            agentKind: agentKind,
            transcriptPath: transcriptPath
        )
        switch operation {
        case .file:
            return snapshot.scope.canonicalFilePath(for: requestedPath)
        case .list:
            return snapshot.scope.canonicalDirectoryListPath(for: requestedPath)
        }
    }

    private static func cacheKey(transcriptPath: String) throws -> CacheKey {
        let attributes = try FileManager.default.attributesOfItem(atPath: transcriptPath)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return CacheKey(transcriptPath: transcriptPath, fileSize: size, modifiedAt: modifiedAt)
    }

    private static func buildSnapshot(
        agentKind: ChatAgentKind,
        transcriptPath: String,
        generation: String
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
        let artifacts = ChatArtifactIndexedReference.derive(from: parseResult.messages)
        let referencedPaths = Set(artifacts.map(\.path))
        return Snapshot(
            referencedPaths: referencedPaths,
            scope: ChatArtifactScope(
                referencedPaths: referencedPaths,
                resolver: ChatArtifactScope.FoundationResolver()
            ),
            artifacts: artifacts,
            generation: generation
        )
    }
}
