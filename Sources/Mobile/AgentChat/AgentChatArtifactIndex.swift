import CmuxAgentChat
import Foundation

/// Builds and caches the transcript-derived artifact scope for chat sessions.
actor AgentChatArtifactIndex {
    struct Snapshot: Sendable {
        let referencedPaths: Set<String>
        let scope: ChatArtifactScope
    }

    enum Operation: Sendable {
        case file
        case list
    }

    private struct CacheKey: Sendable, Equatable {
        let transcriptPath: String
        let fileSize: UInt64
        let modifiedAt: Date
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
        let snapshot = try Self.buildSnapshot(agentKind: agentKind, transcriptPath: transcriptPath)
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
        transcriptPath: String
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
        let referencedPaths = Self.referencedPaths(in: parseResult.messages)
        return Snapshot(
            referencedPaths: referencedPaths,
            scope: ChatArtifactScope(
                referencedPaths: referencedPaths,
                resolver: ChatArtifactScope.FoundationResolver()
            )
        )
    }

    private static func referencedPaths(in messages: [ChatMessage]) -> Set<String> {
        var paths: Set<String> = []
        for message in messages {
            switch message.kind {
            case .attachment(let attachment):
                if let hostPath = attachment.hostPath, !hostPath.isEmpty {
                    paths.insert(hostPath)
                }
            case .fileEdit(let edit):
                paths.insert(edit.filePath)
            case .toolUse(let toolUse):
                for path in toolUse.referencedPaths ?? [] where !path.isEmpty {
                    paths.insert(path)
                }
            case .prose, .thought, .terminal, .permissionRequest, .question, .status, .unsupported:
                continue
            }
        }
        return paths
    }
}
