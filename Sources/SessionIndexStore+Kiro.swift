import Foundation

extension SessionIndexStore {
    /// Reads Kiro's paired CLI metadata and history files through the shared Vault search path.
    nonisolated static func loadKiroEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) -> [SessionEntry] {
        guard offset >= 0, limit > 0, let configuredRoot = registration.sessionDirectory else { return [] }
        let (target, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else { return [] }
        let kiroHome = registration == .builtInKiro
            ? ProcessInfo.processInfo.environment["KIRO_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let root: String
        if let kiroHome, !kiroHome.isEmpty {
            root = ((kiroHome as NSString).expandingTildeInPath as NSString).appendingPathComponent("sessions/cli")
        } else {
            root = (configuredRoot as NSString).expandingTildeInPath
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let candidates = files.compactMap { url -> (metadata: URL, transcript: URL?, modified: Date)? in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            let history = url.deletingPathExtension().appendingPathExtension("jsonl")
            let historyValues = try? history.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            let hasHistory = historyValues?.isRegularFile == true
            let modified = max(
                values.contentModificationDate ?? .distantPast,
                hasHistory ? historyValues?.contentModificationDate ?? .distantPast : .distantPast
            )
            return (url, hasHistory ? history : nil, modified)
        }.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.metadata.lastPathComponent < $1.metadata.lastPathComponent
        }

        var entries: [SessionEntry] = []
        var seen = Set<String>()
        for candidate in candidates.prefix(searchMaxFiles) {
            if Task.isCancelled || entries.count >= target { break }
            guard let metadata = readKiroMetadata(candidate.metadata),
                  let sessionID = metadata["session_id"] as? String,
                  !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let rawCWD = (metadata["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = rawCWD?.isEmpty == false ? rawCWD : nil
            if let cwdFilter, cwd != cwdFilter { continue }
            var title = ""
            if let transcript = candidate.transcript {
                _ = SessionIndexJSONLReader().fromStart(url: transcript, maxBytes: 512 * 1024) { object in
                    guard let record = KiroTranscriptRecord(object: object), record.role == .user else { return false }
                    title = String(record.text.prefix(500))
                    return true
                }
            }
            if !needle.isEmpty {
                let metadataMatches = [sessionID, cwd ?? "", title].contains {
                    $0.range(of: needle, options: [.caseInsensitive, .literal]) != nil
                }
                if !metadataMatches {
                    guard let transcript = candidate.transcript,
                          fileContains(transcript, needle: needle) else { continue }
                }
            }
            guard seen.insert(sessionID).inserted else { continue }
            let launch = kiroHome.flatMap { home -> AgentLaunchCommandSnapshot? in
                guard !home.isEmpty else { return nil }
                return AgentLaunchCommandSnapshot(
                    launcher: "kiro", executablePath: nil, arguments: [registration.defaultExecutable],
                    workingDirectory: cwd, environment: ["KIRO_HOME": (home as NSString).expandingTildeInPath],
                    capturedAt: nil, source: "vault"
                )
            }
            entries.append(SessionEntry(
                id: "kiro:\(sessionID)",
                agent: .registered(RegisteredSessionAgent(registration: registration)),
                sessionId: sessionID, title: title, cwd: cwd, gitBranch: nil, pullRequest: nil,
                modified: candidate.modified, fileURL: candidate.transcript,
                specifics: .registered(registration, launchCommand: launch)
            ))
        }
        return Array(entries.dropFirst(offset).prefix(limit))
    }

    nonisolated private static func readKiroMetadata(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // State includes tool definitions and usage history; never load an unbounded sidecar.
        let byteLimit = 8 * 1024 * 1024
        guard let data = try? handle.read(upToCount: byteLimit + 1), data.count <= byteLimit else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
