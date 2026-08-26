import Foundation

/// Performs the bounded legacy rollout inspection shared by Codex verification
/// requests. The scanner has no retained state; one instance can be reused for
/// every request in a verification batch.
struct CodexLegacyRolloutScanner: Sendable {
    private static let maximumRolloutBytes = 8 * 1024 * 1024
    private static let maximumRolloutLines = 32
    private static let maximumFallbackCandidates = 512
    private static let maximumMatchingCandidates = 32
    private static let maximumScannedEntries = 8_192

    enum RolloutRead {
        case metadata(SessionMetadata)
        case readableWithoutMetadata
        case unavailable
    }

    struct SessionMetadata {
        let sessionId: String
        let provenance: AgentResumeEvidenceProvenance
        let originator: String?
        let sourceDescription: String?
        let parentSessionId: String?
    }

    func scan(
        sessionIDs: Set<String>,
        sessionsRoot: URL,
        fileManager: FileManager
    ) -> (found: [String: (path: String, metadata: SessionMetadata)], sawUnavailable: Bool) {
        guard !sessionIDs.isEmpty else {
            return (found: [:], sawUnavailable: false)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory) else {
            return (found: [:], sawUnavailable: false)
        }
        guard isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: sessionsRoot,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return (found: [:], sawUnavailable: true)
        }

        var fallbackCandidates: [URL] = []
        var sawUnavailable = false
        var scannedEntries = 0
        var matchingCandidatesBySessionID: [String: Int] = [:]
        var found: [String: (path: String, metadata: SessionMetadata)] = [:]
        while let item = enumerator.nextObject() as? URL {
            scannedEntries += 1
            if scannedEntries > Self.maximumScannedEntries {
                sawUnavailable = true
                break
            }
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            let matchingSessionIDs = matchingSessionIDs(
                in: item.lastPathComponent,
                requested: sessionIDs
            )
            if !matchingSessionIDs.isEmpty {
                let eligibleSessionIDs = matchingSessionIDs.filter { sessionID in
                    let count = matchingCandidatesBySessionID[sessionID, default: 0] + 1
                    matchingCandidatesBySessionID[sessionID] = count
                    if count > Self.maximumMatchingCandidates {
                        sawUnavailable = true
                        return false
                    }
                    return true
                }
                guard !eligibleSessionIDs.isEmpty else { continue }
                switch readRollout(atPath: item.path, fileManager: fileManager) {
                case .metadata(let metadata) where eligibleSessionIDs.contains(metadata.sessionId):
                    if found[metadata.sessionId] == nil {
                        found[metadata.sessionId] = (item.path, metadata)
                    }
                case .unavailable:
                    sawUnavailable = true
                default:
                    continue
                }
                if found.count == sessionIDs.count {
                    break
                }
            } else if fallbackCandidates.count < Self.maximumFallbackCandidates {
                fallbackCandidates.append(item)
            }
        }
        guard found.count < sessionIDs.count else {
            return (found: found, sawUnavailable: sawUnavailable)
        }
        for candidate in fallbackCandidates {
            switch readRollout(atPath: candidate.path, fileManager: fileManager) {
            case .metadata(let metadata) where sessionIDs.contains(metadata.sessionId):
                if found[metadata.sessionId] == nil {
                    found[metadata.sessionId] = (candidate.path, metadata)
                }
            case .unavailable:
                sawUnavailable = true
            default:
                continue
            }
            if found.count == sessionIDs.count {
                break
            }
        }
        return (found: found, sawUnavailable: sawUnavailable)
    }

    private func matchingSessionIDs(
        in filename: String,
        requested: Set<String>
    ) -> [String] {
        let bytes = Array(filename.utf8)
        guard bytes.count >= 36 else { return [] }
        var matches: [String] = []
        for start in 0...(bytes.count - 36) {
            let candidate = String(decoding: bytes[start..<(start + 36)], as: UTF8.self)
            guard requested.contains(candidate), !matches.contains(candidate) else { continue }
            matches.append(candidate)
        }
        return matches
    }

    func readRollout(atPath path: String, fileManager: FileManager) -> RolloutRead {
        guard regularNonEmptyFileExists(atPath: path, fileManager: fileManager),
              let handle = FileHandle(forReadingAtPath: path) else {
            return .unavailable
        }
        defer { try? handle.close() }

        var pending = Data()
        var totalBytes = 0
        var lineCount = 0
        var sawJSON = false
        while totalBytes < Self.maximumRolloutBytes, lineCount < Self.maximumRolloutLines {
            guard let chunk = try? handle.read(upToCount: min(64 * 1024, Self.maximumRolloutBytes - totalBytes)),
                  !chunk.isEmpty else {
                break
            }
            totalBytes += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A), lineCount < Self.maximumRolloutLines {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                lineCount += 1
                if let object = jsonObject(line) {
                    sawJSON = true
                    if let metadata = sessionMetadata(from: object) {
                        return .metadata(metadata)
                    }
                }
            }
        }
        if totalBytes >= Self.maximumRolloutBytes && !pending.contains(0x0A) {
            return .unavailable
        }
        if !pending.isEmpty, let object = jsonObject(pending) {
            sawJSON = true
            if let metadata = sessionMetadata(from: object) {
                return .metadata(metadata)
            }
        }
        return sawJSON ? .readableWithoutMetadata : .unavailable
    }

    func sourceContainsMarker(_ marker: String, in value: Any?) -> Bool {
        let normalizedMarker = marker.lowercased()
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedMarker
        }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key.lowercased() == normalizedMarker || sourceContainsMarker(marker, in: child) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains { sourceContainsMarker(marker, in: $0) }
        }
        return false
    }

    private func sessionMetadata(from object: [String: Any]) -> SessionMetadata? {
        guard object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let sessionId = normalized(payload["id"] as? String) else {
            return nil
        }
        let source = payload["source"]
        let sourceDescription = normalized(source as? String)
        let originator = normalized(payload["originator"] as? String)
        let parentSessionId = normalized(payload["parent_thread_id"] as? String)
            ?? normalized(payload["forked_from_id"] as? String)
            ?? nestedString(forKey: "parent_thread_id", in: source)
        let isExec = sourceContainsMarker("exec", in: source)
            || sourceContainsMarker("review", in: source)
            || originator?.lowercased().contains("codex_exec") == true
            || originator?.lowercased().contains("review") == true
        let isSubagent = sourceContainsMarker("subagent", in: source)
            || normalized(payload["thread_source"] as? String)?.lowercased() == "subagent"
        let provenance: AgentResumeEvidenceProvenance
        if isExec {
            provenance = .exec
        } else if isSubagent {
            provenance = .subagent
        } else if sourceContainsMarker("cli", in: source)
                    || sourceContainsMarker("tui", in: source)
                    || sourceContainsMarker("vscode", in: source) {
            provenance = .tui
        } else {
            provenance = .unknown
        }
        return SessionMetadata(
            sessionId: sessionId,
            provenance: provenance,
            originator: originator,
            sourceDescription: sourceDescription,
            parentSessionId: parentSessionId
        )
    }

    private func nestedString(forKey key: String, in value: Any?) -> String? {
        if let dictionary = value as? [String: Any] {
            for (childKey, child) in dictionary {
                if childKey == key, let result = normalized(child as? String) { return result }
                if let result = nestedString(forKey: key, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = nestedString(forKey: key, in: child) {
                    return result
                }
            }
        }
        return nil
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
