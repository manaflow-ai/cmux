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
        guard let resolved = lookup.singleSiblingTranscript(
            projectRoots: candidateProjectDirs,
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

        func append(projectRoot: String) {
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
            let indexedProjectRoots = lookup.workflowProjectRoots(
                configRoot: root,
                sessionId: record.sessionId
            )
            let indexedProjectRootSet = Set(indexedProjectRoots)
            for cwd in cwdCandidates {
                let projectRoot = ((projectsRoot as NSString)
                    .appendingPathComponent(sessionsListEncodeClaudeProjectDir(cwd)) as NSString)
                    .standardizingPath
                if indexedProjectRootSet.contains(projectRoot) {
                    append(projectRoot: projectRoot)
                }
            }
            for projectRoot in indexedProjectRoots {
                append(projectRoot: projectRoot)
            }
        }
        return projectDirs
    }
}
