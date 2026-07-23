import Foundation

/// Collapses open Codex rollout files into one logical parent session.
nonisolated struct CodexRolloutIdentityResolver: Sendable {
    private let maximumSessionMetaBytes = 4 * 1_024 * 1_024

    func resolve(
        openRolloutPaths: [String],
        preferredSessionIDs: Set<String> = [],
        sessionIDFromPath: (String) -> String?
    ) -> CodexRolloutIdentity? {
        var orderedSessionIDs: [String] = []
        var pathBySessionID: [String: String] = [:]
        var parentBySessionID: [String: String] = [:]

        for path in openRolloutPaths {
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
        }

        guard !orderedSessionIDs.isEmpty else { return nil }
        let openSessionIDs = Set(orderedSessionIDs)
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

        let fallback = orderedSessionIDs[0]
        guard let path = pathBySessionID[fallback] else { return nil }
        return CodexRolloutIdentity(sessionID: fallback, transcriptPath: path)
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

    private func sessionMetadata(atPath path: String) -> (sessionID: String?, parentSessionID: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumSessionMetaBytes + 1),
              !data.isEmpty,
              let newline = data.firstIndex(of: 0x0A),
              data.distance(from: data.startIndex, to: newline) <= maximumSessionMetaBytes,
              let object = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return (nil, nil)
        }
        return (
            normalized(payload["id"] as? String),
            normalized(payload["parent_thread_id"] as? String)
        )
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
