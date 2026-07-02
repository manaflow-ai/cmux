import Foundation

extension CMUXCLI {
    func sessionsListResolvedClaudeWorkflowRecord(
        _ record: ClaudeHookSessionRecord,
        lookup: SessionsListClaudeTranscriptLookupCache
    ) -> ClaudeHookSessionRecord {
        guard sessionsListClaudeSessionIdIsSafeFilename(record.sessionId) else {
            return record
        }
        if let transcriptPath = sessionsListNormalized(record.transcriptPath),
           sessionsListRegularNonEmptyFileExists(atPath: (transcriptPath as NSString).expandingTildeInPath) {
            return record
        }

        let roots = lookup.configRoots(record: record)
        guard !roots.isEmpty else { return record }
        let candidateProjectDirs = sessionsListClaudeWorkflowProjectDirs(
            record: record,
            roots: roots,
            lookup: lookup
        )
        guard let resolved = sessionsListNewestClaudeSiblingTranscript(
            in: candidateProjectDirs,
            excludingSessionId: record.sessionId
        ) else {
            return record
        }

        var resolvedRecord = record
        resolvedRecord.sessionId = resolved.sessionId
        resolvedRecord.transcriptPath = resolved.path
        return resolvedRecord
    }

    private func sessionsListClaudeWorkflowProjectDirs(
        record: ClaudeHookSessionRecord,
        roots: [String],
        lookup: SessionsListClaudeTranscriptLookupCache
    ) -> [String] {
        var projectDirs: [String] = []
        var seen: Set<String> = []

        func appendIfWorkflowContainer(projectRoot: String) {
            let workflowContainer = (projectRoot as NSString).appendingPathComponent(record.sessionId)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workflowContainer, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let standardized = (projectRoot as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            projectDirs.append(standardized)
        }

        let cwdCandidates = [
            sessionsListNormalized(record.launchCommand?.workingDirectory),
            sessionsListNormalized(record.cwd),
        ].compactMap { $0 }
        for root in roots {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            for cwd in cwdCandidates {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString)
                        .appendingPathComponent(sessionsListEncodeClaudeProjectDir(cwd))
                )
            }
            for projectDir in lookup.projectDirs(configRoot: root) {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(projectDir)
                )
            }
        }
        return projectDirs
    }

    private func sessionsListNewestClaudeSiblingTranscript(
        in projectDirs: [String],
        excludingSessionId excludedSessionId: String
    ) -> (sessionId: String, path: String)? {
        var best: (sessionId: String, path: String, modifiedAt: TimeInterval)?
        for projectDir in projectDirs {
            sessionsListNewestClaudeTranscript(
                inDirectory: projectDir,
                excludingSessionId: excludedSessionId,
                remainingDirectoryDepth: 4,
                best: &best
            )
        }
        guard let best else { return nil }
        return (best.sessionId, best.path)
    }

    private func sessionsListNewestClaudeTranscript(
        inDirectory directory: String,
        excludingSessionId excludedSessionId: String,
        remainingDirectoryDepth: Int,
        best: inout (sessionId: String, path: String, modifiedAt: TimeInterval)?
    ) {
        guard sessionsListDirectoryExists(atPath: directory),
              let children = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        for child in children {
            let childPath = (directory as NSString).appendingPathComponent(child)
            if child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard sessionId != excludedSessionId,
                      sessionsListClaudeSessionIdIsSafeFilename(sessionId),
                      sessionsListRegularNonEmptyFileExists(atPath: childPath) else {
                    continue
                }
                let modifiedAt = ((try? FileManager.default.attributesOfItem(atPath: childPath)[.modificationDate]) as? Date)?
                    .timeIntervalSince1970 ?? 0
                if best == nil || modifiedAt > best!.modifiedAt {
                    best = (sessionId, childPath, modifiedAt)
                }
            } else if remainingDirectoryDepth > 0 {
                sessionsListNewestClaudeTranscript(
                    inDirectory: childPath,
                    excludingSessionId: excludedSessionId,
                    remainingDirectoryDepth: remainingDirectoryDepth - 1,
                    best: &best
                )
            }
        }
    }
}
