import Foundation

extension AgentHibernationTranscriptGuard {
    static func resolveClaudeTranscriptPath(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey?,
        homeDirectory: String,
        fileManager: FileManager
    ) -> String? {
        var metadataOnlyCandidate: String?
        var seenCandidates: Set<String> = []

        func appendCandidate(_ path: String, to candidates: inout [String]) {
            let standardized = (path as NSString).standardizingPath
            guard seenCandidates.insert(standardized).inserted,
                  isRegularFile(atPath: path, fileManager: fileManager) else { return }
            candidates.append(path)
        }

        func resolve(_ candidates: [String], requireUniqueConversation: Bool = false) -> (path: String?, shouldStop: Bool) {
            let resolution = transcriptCandidateResolution(
                candidates,
                requireUniqueConversation: requireUniqueConversation,
                fileManager: fileManager
            )
            metadataOnlyCandidate = metadataOnlyCandidate ?? resolution.metadataOnlyPath
            return (resolution.path, resolution.shouldStop)
        }

        let recordedTranscript = recordedTranscriptPath(
            agent: agent,
            panelKey: panelKey,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        if recordedTranscript.isAmbiguous {
            return nil
        }
        if let recordedPath = recordedTranscript.path {
            var candidates: [String] = []
            appendCandidate(recordedPath, to: &candidates)
            let resolution = resolve(candidates)
            if resolution.shouldStop { return resolution.path }
        }

        let configRoots = claudeConfigRoots(for: agent, homeDirectory: homeDirectory, fileManager: fileManager)
        if let workingDirectory = normalized(agent.workingDirectory) {
            var standardCandidates: [String] = []
            var workflowCandidates: [String] = []
            for configRoot in configRoots {
                let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
                let projectRoot = (projectsRoot as NSString)
                    .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory))
                for candidate in transcriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId) {
                    appendCandidate(candidate, to: &standardCandidates)
                }
                for candidate in workflowTranscriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId, fileManager: fileManager) {
                    appendCandidate(candidate, to: &workflowCandidates)
                }
            }
            let standardResolution = resolve(standardCandidates, requireUniqueConversation: true)
            if standardResolution.shouldStop { return standardResolution.path }
            let workflowResolution = resolve(workflowCandidates, requireUniqueConversation: true)
            if workflowResolution.shouldStop { return workflowResolution.path }
        }

        var fallbackCandidates: [String] = []
        for configRoot in configRoots {
            let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
            guard let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else { continue }
            for projectDir in projectDirs.sorted() {
                let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDir)
                for candidate in transcriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId) {
                    appendCandidate(candidate, to: &fallbackCandidates)
                }
                for candidate in workflowTranscriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId, fileManager: fileManager) {
                    appendCandidate(candidate, to: &fallbackCandidates)
                }
            }
        }
        let fallbackResolution = resolve(fallbackCandidates, requireUniqueConversation: true)
        if fallbackResolution.shouldStop { return fallbackResolution.path }
        return metadataOnlyCandidate
    }

    private static func transcriptCandidateResolution(
        _ candidates: [String],
        requireUniqueConversation: Bool = false,
        fileManager: FileManager
    ) -> (path: String?, metadataOnlyPath: String?, shouldStop: Bool) {
        var metadataOnlyPath: String?
        var conversationPath: String?
        for candidate in candidates {
            if transcriptHasConversationTurns(atPath: candidate, fileManager: fileManager) {
                guard requireUniqueConversation else {
                    return (candidate, metadataOnlyPath, true)
                }
                if conversationPath != nil { return (nil, metadataOnlyPath, true) }
                conversationPath = candidate
                continue
            }
            if transcriptContainsOnlyNonProtectiveMetadata(atPath: candidate, fileManager: fileManager) {
                metadataOnlyPath = metadataOnlyPath ?? candidate
                continue
            }
            return (nil, metadataOnlyPath, true)
        }
        if let conversationPath { return (conversationPath, metadataOnlyPath, true) }
        return (nil, metadataOnlyPath, false)
    }

    static func workflowTranscriptCandidates(
        projectRoot: String,
        sessionId: String,
        fileManager: FileManager
    ) -> [String] {
        let targetName = "\(sessionId).jsonl"
        let directPath = (projectRoot as NSString).appendingPathComponent(targetName)
        let nestedPath = (((projectRoot as NSString).appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent(targetName)
        let standardPaths = Set([directPath, nestedPath].map { ($0 as NSString).standardizingPath })
        var matches: [String] = []
        var hasMetadataOnlyMatch = false
        var protectiveMatchCount = 0
        collectWorkflowTranscriptCandidates(
            inDirectory: projectRoot,
            targetName: targetName,
            excludedPaths: standardPaths,
            remainingDirectoryDepth: 4,
            fileManager: fileManager,
            matches: &matches,
            hasMetadataOnlyMatch: &hasMetadataOnlyMatch,
            protectiveMatchCount: &protectiveMatchCount
        )
        return matches
    }

    private static func collectWorkflowTranscriptCandidates(
        inDirectory directory: String,
        targetName: String,
        excludedPaths: Set<String>,
        remainingDirectoryDepth: Int,
        fileManager: FileManager,
        matches: inout [String],
        hasMetadataOnlyMatch: inout Bool,
        protectiveMatchCount: inout Int
    ) {
        guard protectiveMatchCount < 2,
              let children = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return
        }
        for child in children.sorted() {
            guard protectiveMatchCount < 2 else { return }
            let childPath = (directory as NSString).appendingPathComponent(child)
            if child == targetName {
                let standardized = (childPath as NSString).standardizingPath
                guard !excludedPaths.contains(standardized),
                      workflowRegularNonEmptyFileExists(atPath: childPath, fileManager: fileManager) else {
                    continue
                }
                if transcriptContainsOnlyNonProtectiveMetadata(atPath: childPath, fileManager: fileManager) {
                    if !hasMetadataOnlyMatch {
                        matches.append(childPath)
                        hasMetadataOnlyMatch = true
                    }
                    continue
                }
                matches.append(childPath)
                protectiveMatchCount += 1
            } else if remainingDirectoryDepth > 0,
                      workflowDirectoryExists(atPath: childPath, fileManager: fileManager) {
                collectWorkflowTranscriptCandidates(
                    inDirectory: childPath,
                    targetName: targetName,
                    excludedPaths: excludedPaths,
                    remainingDirectoryDepth: remainingDirectoryDepth - 1,
                    fileManager: fileManager,
                    matches: &matches,
                    hasMetadataOnlyMatch: &hasMetadataOnlyMatch,
                    protectiveMatchCount: &protectiveMatchCount
                )
            }
        }
    }

    private static func workflowRegularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return false
        }
        return ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
    }

    private static func workflowDirectoryExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
