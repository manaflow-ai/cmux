import Foundation

/// Collapses open Codex rollout files into one logical parent session.
nonisolated struct CodexRolloutIdentityResolver: Sendable {
    private let maximumSessionMetaBytes = 4 * 1_024 * 1_024
    private let sessionMetaReadChunkBytes = 4 * 1_024

    func resolve(
        openRolloutPaths: [String],
        preferredSessionIDs: Set<String> = [],
        sessionIDFromPath: (String) -> String?
    ) -> CodexRolloutIdentity? {
        var orderedSessionIDs: [String] = []
        var pathBySessionID: [String: String] = [:]
        var parentBySessionID: [String: String] = [:]
        var canonicalSessionIDBySessionID: [String: String] = [:]
        var seenPaths: Set<String> = []

        for path in openRolloutPaths where seenPaths.insert(path).inserted {
            guard !Task.isCancelled else { return nil }
            let fallbackSessionID = sessionIDFromPath((path as NSString).lastPathComponent)
            let metadata = sessionMetadata(atPath: path)
            guard let sessionID = metadata.sessionID ?? fallbackSessionID else { continue }
            if pathBySessionID[sessionID] == nil {
                orderedSessionIDs.append(sessionID)
                pathBySessionID[sessionID] = path
            }
            if let parentSessionID = metadata.parentSessionID,
               parentSessionID != sessionID {
                parentBySessionID[sessionID] = parentSessionID
            }
            if let canonicalSessionID = metadata.canonicalSessionID {
                canonicalSessionIDBySessionID[sessionID] = canonicalSessionID
            }
        }

        guard !orderedSessionIDs.isEmpty else { return nil }
        let openSessionIDs = Set(orderedSessionIDs)
        let canonicalSessionIDs = orderedSessionIDs.compactMap {
            canonicalSessionIDBySessionID[$0]
        }
        if let canonicalSessionID = Set(canonicalSessionIDs).onlyElement,
           orderedSessionIDs.allSatisfy({ sessionID in
               sessionID == canonicalSessionID
                   || canonicalSessionIDBySessionID[sessionID] == canonicalSessionID
           }),
           let path = pathBySessionID[canonicalSessionID] {
            return CodexRolloutIdentity(
                sessionID: canonicalSessionID,
                transcriptPath: path
            )
        }

        let roots = orderedSessionIDs.compactMap {
            rootSessionID(
                for: $0,
                parentBySessionID: parentBySessionID,
                openSessionIDs: openSessionIDs
            )
        }
        if roots.count == orderedSessionIDs.count,
           let root = Set(roots).onlyElement,
           let path = pathBySessionID[root] {
            return CodexRolloutIdentity(sessionID: root, transcriptPath: path)
        }

        if let preferred = orderedSessionIDs.first(where: preferredSessionIDs.contains),
           let path = pathBySessionID[preferred] {
            return CodexRolloutIdentity(sessionID: preferred, transcriptPath: path)
        }

        return nil
    }

    private func rootSessionID(
        for sessionID: String,
        parentBySessionID: [String: String],
        openSessionIDs: Set<String>
    ) -> String? {
        var current = sessionID
        var visited: Set<String> = []
        while let parent = parentBySessionID[current], openSessionIDs.contains(parent) {
            guard visited.insert(current).inserted else { return nil }
            current = parent
        }
        return current
    }

    private func sessionMetadata(
        atPath path: String
    ) -> (sessionID: String?, canonicalSessionID: String?, parentSessionID: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        guard let data = sessionMetaLine(from: handle),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return (nil, nil, nil)
        }
        return (
            normalized(payload["id"] as? String),
            normalized(payload["session_id"] as? String),
            normalized(payload["parent_thread_id"] as? String)
        )
    }

    private func sessionMetaLine(from handle: FileHandle) -> Data? {
        var line = Data()
        while line.count <= maximumSessionMetaBytes {
            guard !Task.isCancelled,
                  let chunk = try? handle.read(
                      upToCount: min(
                          sessionMetaReadChunkBytes,
                          maximumSessionMetaBytes + 1 - line.count
                      )
                  ),
                  !chunk.isEmpty else {
                return nil
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                let prefix = chunk[..<newline]
                guard line.count + prefix.count <= maximumSessionMetaBytes else { return nil }
                line.append(contentsOf: prefix)
                return line
            }
            line.append(chunk)
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private extension Set {
    var onlyElement: Element? {
        count == 1 ? first : nil
    }
}
