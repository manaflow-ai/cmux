import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService: AgentRecentFileProviding {
    func recentFiles(in scope: AgentRecentFileScope, limit: Int) async -> [AgentRecentFile] {
        guard limit > 0 else { return [] }
        let records = registry.sessions(workspaceID: nil)
            .filter { supportsRecentFiles(agentKind: $0.agentKind) && session($0, belongsTo: scope) }
            .prefix(16)
        var latestByPath: [String: AgentRecentFile] = [:]

        for record in records {
            for message in await recentFileMessages(for: record) {
                guard case .fileEdit(let edit) = message.kind,
                      edit.operation != .delete,
                      let file = recentFile(edit: edit, message: message, record: record, scope: scope) else {
                    continue
                }
                if let existing = latestByPath[file.path], existing.modifiedAt > file.modifiedAt {
                    continue
                }
                latestByPath[file.path] = file
            }
        }

        return Array(
            latestByPath.values
                .sorted {
                    if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                    return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
                .prefix(limit)
        )
    }

    private func recentFileMessages(for record: AgentChatSessionRecord) async -> [ChatMessage] {
        if case .ended = record.state {
            guard let path = resolver.transcriptPath(for: record) else { return [] }
            let tailer = AgentChatTranscriptTailer(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                path: path,
                onBatch: { _ in }
            )
            await tailer.loadSnapshot()
            return await tailer.history(beforeSeq: nil, limit: 1_000).messages
        }
        return await history(sessionID: record.sessionID, beforeSeq: nil, limit: 1_000)?.messages ?? []
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            recentFileChangeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recentFileChangeContinuations[id] = nil
                }
            }
        }
    }

    func yieldRecentAgentFileChanges() {
        for continuation in recentFileChangeContinuations.values {
            continuation.yield(())
        }
    }

    private func supportsRecentFiles(agentKind: ChatAgentKind) -> Bool {
        switch agentKind {
        case .claude, .codex:
            return true
        case .other:
            return false
        }
    }

    private func session(_ record: AgentChatSessionRecord, belongsTo scope: AgentRecentFileScope) -> Bool {
        if let workspaceID = scope.workspaceID, record.workspaceID == workspaceID {
            return true
        }
        guard let root = scope.rootDirectory,
              let workingDirectory = record.workingDirectory else {
            return false
        }
        return path(normalizedPath(workingDirectory), isWithin: normalizedPath(root))
    }

    private func recentFile(
        edit: ChatFileEdit,
        message: ChatMessage,
        record: AgentChatSessionRecord,
        scope: AgentRecentFileScope
    ) -> AgentRecentFile? {
        let rawPath = edit.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        let resolvedPath: String
        if rawPath.hasPrefix("/") {
            resolvedPath = normalizedPath(rawPath)
        } else if let base = record.workingDirectory ?? scope.rootDirectory {
            resolvedPath = normalizedPath((normalizedPath(base) as NSString).appendingPathComponent(rawPath))
        } else {
            return nil
        }

        let relativePath: String
        if let rootDirectory = scope.rootDirectory {
            let root = normalizedPath(rootDirectory)
            guard path(resolvedPath, isWithin: root) else { return nil }
            relativePath = pathRelativeToRoot(resolvedPath, root: root)
        } else {
            relativePath = rawPath.hasPrefix("/") ? resolvedPath : rawPath
        }
        guard !relativePath.isEmpty else { return nil }
        return AgentRecentFile(
            path: resolvedPath,
            relativePath: relativePath,
            agentKind: record.agentKind,
            operation: edit.operation,
            modifiedAt: message.timestamp
        )
    }

    private func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func path(_ candidate: String, isWithin root: String) -> Bool {
        if root == "/" { return candidate.hasPrefix("/") }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func pathRelativeToRoot(_ path: String, root: String) -> String {
        if path == root { return (path as NSString).lastPathComponent }
        if root == "/" { return String(path.dropFirst()) }
        return String(path.dropFirst(root.count + 1))
    }
}
