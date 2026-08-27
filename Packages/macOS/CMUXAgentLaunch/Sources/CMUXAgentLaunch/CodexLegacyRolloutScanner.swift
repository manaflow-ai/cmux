import Foundation

/// Performs the bounded legacy rollout inspection shared by Codex verification
/// requests. The scanner has no retained state; one instance can be reused for
/// every request in a verification batch.
struct CodexLegacyRolloutScanner: Sendable {
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
        fileManager: FileManager,
        readBudget: inout CodexSessionResumeVerificationLimits
    ) -> (found: [String: (path: String, metadata: SessionMetadata)], sawUnavailable: Bool) {
        guard !sessionIDs.isEmpty else {
            return (found: [:], sawUnavailable: false)
        }
        guard readBudget.hasRemainingBytes else {
            return (found: [:], sawUnavailable: true)
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
            if !readBudget.hasRemainingBytes {
                sawUnavailable = true
                break
            }
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
                switch readRollout(
                    atPath: item.path,
                    fileManager: fileManager,
                    readBudget: &readBudget
                ) {
                case .metadata(let metadata):
                    guard sessionIDs.contains(metadata.sessionId) else { break }
                    // A rollout may have been renamed or copied while its
                    // `session_meta.id` stayed authoritative. Keep metadata
                    // matches even when the filename's UUID points at a
                    // different requested record.
                    let count: Int
                    if eligibleSessionIDs.contains(metadata.sessionId) {
                        count = matchingCandidatesBySessionID[metadata.sessionId, default: 0]
                    } else {
                        count = matchingCandidatesBySessionID[metadata.sessionId, default: 0] + 1
                        matchingCandidatesBySessionID[metadata.sessionId] = count
                    }
                    if count <= Self.maximumMatchingCandidates,
                       found[metadata.sessionId] == nil {
                        found[metadata.sessionId] = (item.path, metadata)
                    } else if count > Self.maximumMatchingCandidates {
                        sawUnavailable = true
                    }
                case .unavailable:
                    sawUnavailable = true
                case .readableWithoutMetadata:
                    break
                }
                if !readBudget.hasRemainingBytes {
                    sawUnavailable = true
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
            guard readBudget.hasRemainingBytes else {
                sawUnavailable = true
                break
            }
            switch readRollout(
                atPath: candidate.path,
                fileManager: fileManager,
                readBudget: &readBudget
            ) {
            case .metadata(let metadata):
                guard sessionIDs.contains(metadata.sessionId) else { break }
                if found[metadata.sessionId] == nil {
                    found[metadata.sessionId] = (candidate.path, metadata)
                }
            case .unavailable:
                sawUnavailable = true
            case .readableWithoutMetadata:
                break
            }
            if !readBudget.hasRemainingBytes {
                sawUnavailable = true
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
        // Codex normally uses UUIDs, but older/fixture stores may use another
        // stable identifier. Preserve the original focused `contains` probe;
        // metadata validation below remains the authority for exact identity.
        requested
            .filter { !$0.isEmpty && filename.contains($0) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0 < $1
            }
    }

    func readRollout(
        atPath path: String,
        fileManager: FileManager,
        readBudget: inout CodexSessionResumeVerificationLimits
    ) -> RolloutRead {
        guard let maximumBytes = readBudget.allowance(for: path, fileManager: fileManager) else {
            return .unavailable
        }
        let fileSize = (try? fileManager.attributesOfItem(atPath: path))
            .flatMap { $0[.size] as? NSNumber }
            .map(\.int64Value)
        let fileWasTruncated = fileSize.map {
            $0 > Int64(maximumBytes)
                || (maximumBytes == CodexSessionResumeVerificationLimits.maximumRolloutBytes
                    && $0 >= Int64(maximumBytes))
        } == true
        return readRollout(
            atPath: path,
            fileManager: fileManager,
            maximumBytes: maximumBytes,
            fileWasTruncated: fileWasTruncated
        )
    }

    private func readRollout(
        atPath path: String,
        fileManager: FileManager,
        maximumBytes: Int,
        fileWasTruncated: Bool
    ) -> RolloutRead {
        guard regularNonEmptyFileExists(atPath: path, fileManager: fileManager),
              let handle = FileHandle(forReadingAtPath: path) else {
            return .unavailable
        }
        defer { try? handle.close() }

        var pending = Data()
        var totalBytes = 0
        var lineCount = 0
        var sawJSON = false
        while totalBytes < maximumBytes, lineCount < CodexSessionResumeVerificationLimits.maximumRolloutLines {
            guard let chunk = try? handle.read(upToCount: min(64 * 1024, maximumBytes - totalBytes)),
                  !chunk.isEmpty else {
                break
            }
            totalBytes += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A), lineCount < CodexSessionResumeVerificationLimits.maximumRolloutLines {
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
        if !pending.isEmpty, let object = jsonObject(pending) {
            sawJSON = true
            if let metadata = sessionMetadata(from: object) {
                return .metadata(metadata)
            }
        }
        if fileWasTruncated && totalBytes >= maximumBytes && !pending.contains(0x0A) {
            // Parse the pending final object before treating a byte-ceiling
            // truncation as an inconclusive read.
            return .unavailable
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
