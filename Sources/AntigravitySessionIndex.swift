import Foundation

extension SessionIndexStore {
    private struct AntigravityHistoryMetadata {
        let sessionId: String
        let title: String
        let cwd: String?
        let modified: Date
        let fileURL: URL
    }

    private struct AntigravityPendingHistoryMetadata {
        let title: String
        let cwd: String?
        let modified: Date
    }

    private struct AntigravityHistorySnapshot {
        var bySessionID: [String: AntigravityHistoryMetadata] = [:]
        var pending: [AntigravityPendingHistoryMetadata] = []
    }

    private struct AntigravityTranscriptMetadata {
        var title: String = ""
    }

    nonisolated private static let antigravityHistoryMetadataByteCap = 4 * 1024 * 1024
    nonisolated private static let antigravityTranscriptMetadataByteCap = 512 * 1024
    nonisolated private static let antigravityLastConversationsByteCap = 1024 * 1024
    nonisolated private static let antigravityPendingHistoryMatchWindow: TimeInterval = 24 * 60 * 60

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadAntigravityEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) async -> [SessionEntry] {
        guard limit > 0 else { return [] }
        let roots = antigravitySessionRoots(registration: registration)
        guard !roots.isEmpty else { return [] }

        var matches: [SessionEntry] = []
        var seenSessionIDs = Set<String>()
        var scannedTranscripts = 0
        let normalizedCWDFilter = normalizedAntigravityCWD(cwdFilter)

        for root in roots {
            if Task.isCancelled { break }
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            let historySnapshot = antigravityHistorySnapshot(rootURL: rootURL)
            let historyBySessionID = historySnapshot.bySessionID
            let cwdBySessionID = antigravityLastConversationCWDBySessionID(rootURL: rootURL)
            let candidates = enumerateAntigravityTranscriptCandidates(rootURL: rootURL)
                .sorted {
                    if $0.modified == $1.modified {
                        return $0.sessionId < $1.sessionId
                    }
                    return $0.modified > $1.modified
                }

            for candidate in candidates {
                if Task.isCancelled { break }
                if scannedTranscripts >= searchMaxFiles { break }
                scannedTranscripts += 1

                let history = historyBySessionID[candidate.sessionId]
                let transcriptMetadata = antigravityTranscriptMetadata(url: candidate.url)
                let pendingHistory: AntigravityPendingHistoryMetadata?
                if history == nil {
                    pendingHistory = antigravityPendingHistoryMatch(
                        title: transcriptMetadata.title,
                        modified: candidate.modified,
                        pending: historySnapshot.pending
                    )
                } else {
                    pendingHistory = nil
                }
                let title = normalizedAntigravityValue(transcriptMetadata.title)
                    ?? normalizedAntigravityValue(history?.title)
                    ?? normalizedAntigravityValue(pendingHistory?.title)
                    ?? candidate.sessionId
                let cwd = normalizedAntigravityCWD(history?.cwd)
                    ?? normalizedAntigravityCWD(pendingHistory?.cwd)
                    ?? cwdBySessionID[candidate.sessionId]
                if let normalizedCWDFilter, cwd != normalizedCWDFilter { continue }
                guard antigravityHistoryMatchesNeedle(
                    needle: needle,
                    sessionId: candidate.sessionId,
                    title: title,
                    cwd: cwd
                ) else {
                    continue
                }

                guard seenSessionIDs.insert(candidate.sessionId).inserted else { continue }
                let modified = max(
                    candidate.modified,
                    history?.modified ?? pendingHistory?.modified ?? Date.distantPast
                )
                matches.append(SessionEntry(
                    id: "\(registration.id):\(candidate.sessionId)",
                    agent: .registered(RegisteredSessionAgent(registration: registration)),
                    sessionId: candidate.sessionId,
                    title: title,
                    cwd: cwd,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: modified,
                    fileURL: candidate.url,
                    specifics: .registered(registration)
                ))
            }

            let historyFallbacks = historyBySessionID.values.sorted {
                if $0.modified == $1.modified {
                    return $0.sessionId < $1.sessionId
                }
                return $0.modified > $1.modified
            }
            for metadata in historyFallbacks {
                if Task.isCancelled { break }
                guard seenSessionIDs.insert(metadata.sessionId).inserted else { continue }
                let title = normalizedAntigravityValue(metadata.title) ?? metadata.sessionId
                let cwd = normalizedAntigravityCWD(metadata.cwd)
                if let normalizedCWDFilter, cwd != normalizedCWDFilter { continue }
                guard antigravityHistoryMatchesNeedle(
                    needle: needle,
                    sessionId: metadata.sessionId,
                    title: title,
                    cwd: cwd
                ) else {
                    continue
                }
                matches.append(SessionEntry(
                    id: "\(registration.id):\(metadata.sessionId)",
                    agent: .registered(RegisteredSessionAgent(registration: registration)),
                    sessionId: metadata.sessionId,
                    title: title,
                    cwd: cwd,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: metadata.modified,
                    fileURL: metadata.fileURL,
                    specifics: .registered(registration)
                ))
            }

            if scannedTranscripts >= searchMaxFiles {
                break
            }
        }

        let entries = matches.sorted {
            if $0.modified == $1.modified {
                return $0.sessionId < $1.sessionId
            }
            return $0.modified > $1.modified
        }
        return Array(entries.dropFirst(offset).prefix(limit))
    }

    nonisolated private static func antigravitySessionRoots(
        registration: CmuxVaultAgentRegistration
    ) -> [String] {
        guard let root = registration.sessionDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else {
            return []
        }
        return [(root as NSString).expandingTildeInPath]
    }

    nonisolated private static func antigravityHistorySnapshot(
        rootURL: URL
    ) -> AntigravityHistorySnapshot {
        let historyURL = rootURL.appendingPathComponent("history.jsonl", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: historyURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return AntigravityHistorySnapshot()
        }
        let fallbackModified = ((try? FileManager.default.attributesOfItem(atPath: historyURL.path))?[.modificationDate] as? Date)
            ?? Date.distantPast
        var snapshot = AntigravityHistorySnapshot()
        let tail = readFileTail(url: historyURL, byteCap: antigravityHistoryMetadataByteCap)
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            if Task.isCancelled { return snapshot }
            let data = Data(line.utf8)
            guard let object = autoreleasepool(invoking: { () -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }) else {
                continue
            }
            let title = antigravityHistoryTitle(in: object) ?? ""
            let cwd = antigravityFirstString(in: object, keys: antigravityCWDKeys())
            let modified = antigravityHistoryModifiedDate(in: object, fallback: fallbackModified)
            guard let sessionId = antigravityFirstString(in: object, keys: antigravitySessionIDKeys()) else {
                snapshot.pending.append(
                    AntigravityPendingHistoryMetadata(
                        title: title,
                        cwd: cwd,
                        modified: modified
                    )
                )
                continue
            }
            let metadata = AntigravityHistoryMetadata(
                sessionId: sessionId,
                title: title,
                cwd: cwd,
                modified: modified,
                fileURL: historyURL
            )
            if let existing = snapshot.bySessionID[sessionId], existing.modified > metadata.modified {
                continue
            }
            snapshot.bySessionID[sessionId] = metadata
        }
        return snapshot
    }

    nonisolated private static func antigravityPendingHistoryMatch(
        title: String,
        modified: Date,
        pending: [AntigravityPendingHistoryMetadata]
    ) -> AntigravityPendingHistoryMetadata? {
        guard let normalizedTitle = normalizedAntigravityValue(title) else { return nil }
        let lowercasedTitle = normalizedTitle.lowercased()
        return pending
            .filter { metadata in
                guard let metadataTitle = normalizedAntigravityValue(metadata.title) else {
                    return false
                }
                let delta = abs(metadata.modified.timeIntervalSince(modified))
                return metadataTitle.lowercased() == lowercasedTitle
                    && delta <= antigravityPendingHistoryMatchWindow
            }
            .min {
                abs($0.modified.timeIntervalSince(modified))
                    < abs($1.modified.timeIntervalSince(modified))
            }
    }

    nonisolated private static func antigravityLastConversationCWDBySessionID(
        rootURL: URL
    ) -> [String: String] {
        let url = rootURL
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("last_conversations.json", isDirectory: false)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let fileSize = values?.fileSize,
              fileSize <= antigravityLastConversationsByteCap,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (cwd, sessionId) in object {
            guard let normalizedCWD = normalizedAntigravityCWD(cwd),
                  let normalizedSessionID = normalizedAntigravityValue(sessionId) else {
                continue
            }
            result[normalizedSessionID] = normalizedCWD
        }
        return result
    }

    nonisolated private static func enumerateAntigravityTranscriptCandidates(
        rootURL: URL
    ) -> [(sessionId: String, url: URL, modified: Date)] {
        let brainURL = rootURL.appendingPathComponent("brain", isDirectory: true)
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: brainURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var candidates: [(sessionId: String, url: URL, modified: Date)] = []
        for sessionDir in sessionDirs {
            if Task.isCancelled { break }
            let values = try? sessionDir.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let transcriptURL = sessionDir
                .appendingPathComponent(".system_generated", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl", isDirectory: false)
            let transcriptValues = try? transcriptURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            guard transcriptValues?.isRegularFile == true,
                  let modified = transcriptValues?.contentModificationDate else {
                continue
            }
            candidates.append((sessionDir.lastPathComponent, transcriptURL, modified))
        }
        return candidates
    }

    nonisolated private static func antigravityTranscriptMetadata(
        url: URL
    ) -> AntigravityTranscriptMetadata {
        var metadata = AntigravityTranscriptMetadata()
        forEachJSONLine(url: url, maxBytes: antigravityTranscriptMetadataByteCap) { object in
            if Task.isCancelled { return true }
            if metadata.title.isEmpty,
               let text = antigravityTranscriptUserRequest(in: object) {
                metadata.title = text
            }
            return !metadata.title.isEmpty
        }
        return metadata
    }

    nonisolated private static func antigravityTranscriptUserRequest(in object: [String: Any]) -> String? {
        guard (object["source"] as? String) == "USER_EXPLICIT",
              (object["type"] as? String) == "USER_INPUT",
              let content = object["content"] as? String else {
            return nil
        }
        return AntigravityTranscriptPreview.userRequestText(from: content)
            ?? normalizedAntigravityValue(content)
    }

    nonisolated private static func normalizedAntigravityValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func normalizedAntigravityCWD(_ value: String?) -> String? {
        normalizedAntigravityValue(value).map { ($0 as NSString).standardizingPath }
    }

    nonisolated private static func antigravityCWDKeys() -> [String] {
        ["cwd", "workingDirectory", "workspacePath", "workspace", "projectPath", "directory"]
    }

    nonisolated private static func antigravitySessionIDKeys() -> [String] {
        ["conversationId", "conversation_id", "sessionId", "session_id", "id"]
    }

    nonisolated private static func antigravityHistoryTitle(in object: [String: Any]) -> String? {
        antigravityFirstText(in: object, keys: ["title", "prompt", "display"])
            ?? antigravityFirstTopLevelTitle(in: object)
    }

    nonisolated private static func antigravityHistoryMatchesNeedle(
        needle: String,
        sessionId: String,
        title: String,
        cwd: String?
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        return [sessionId, title, cwd ?? ""].contains { value in
            value.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }
    }

    nonisolated private static func antigravityHistoryModifiedDate(
        in object: [String: Any],
        fallback: Date
    ) -> Date {
        guard let timestamp = antigravityNumericTimestamp(object["timestamp"]) else {
            return fallback
        }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return Date(timeIntervalSince1970: seconds)
    }

    nonisolated private static func antigravityNumericTimestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated private static func antigravityFirstString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            if let trimmed = normalizedAntigravityValue(value) {
                return trimmed
            }
        }
        return nil
    }

    nonisolated private static func antigravityFirstText(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let text = antigravityFirstTextValue(object[key]) else { continue }
            return text
        }
        return nil
    }

    nonisolated private static func antigravityFirstTopLevelTitle(in object: [String: Any]) -> String? {
        if let title = antigravityFirstText(in: object, keys: ["title", "prompt"]) {
            return title
        }
        guard antigravityShouldUseMessageAsTitle(object) else { return nil }
        return antigravityFirstText(in: object, keys: ["text", "content"])
    }

    nonisolated private static func antigravityFirstTextValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return normalizedAntigravityValue(string)
        }
        if let values = value as? [Any] {
            for value in values {
                if let text = antigravityFirstTextBlock(value) {
                    return text
                }
            }
        }
        if let block = value as? [String: Any] {
            return antigravityFirstTextBlock(block)
        }
        return nil
    }

    nonisolated private static func antigravityFirstTextBlock(_ value: Any) -> String? {
        if let string = value as? String {
            return normalizedAntigravityValue(string)
        }
        guard let block = value as? [String: Any] else { return nil }
        guard let type = antigravityFirstString(in: block, keys: ["type"]),
              type.caseInsensitiveCompare("text") == .orderedSame else {
            return nil
        }
        return antigravityFirstString(in: block, keys: ["text"])
    }

    nonisolated private static func antigravityShouldUseMessageAsTitle(_ message: [String: Any]) -> Bool {
        guard let role = antigravityFirstString(in: message, keys: ["role"]) else {
            return true
        }
        return role.caseInsensitiveCompare("user") == .orderedSame
    }
}
