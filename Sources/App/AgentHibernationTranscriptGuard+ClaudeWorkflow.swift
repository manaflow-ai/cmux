import Darwin
import Foundation

extension AgentHibernationTranscriptGuard {
    private static let maximumClaudeWorkflowScanEntries = 16_384
    private static let maximumClaudeWorkflowScanBytes: UInt64 = 64 * 1_024 * 1_024

    private struct ClaudeWorkflowScanBudget {
        var remainingEntries = maximumClaudeWorkflowScanEntries
        var remainingBytes = maximumClaudeWorkflowScanBytes

        mutating func consumeEntry() -> Bool {
            guard remainingEntries > 0 else { return false }
            remainingEntries -= 1
            return true
        }

        mutating func consumeFile(byteCount: UInt64) -> Bool {
            guard byteCount <= remainingBytes else { return false }
            remainingBytes -= byteCount
            return true
        }
    }

    private struct ClaudeTranscriptCandidateAccumulator {
        private(set) var conversationPath: String?
        private(set) var metadataOnlyPath: String?
        private(set) var isUnsafeOrAmbiguous = false

        mutating func inspect(path: String, fileManager: FileManager) {
            guard !isUnsafeOrAmbiguous else { return }
            if transcriptHasConversationTurns(atPath: path, fileManager: fileManager) {
                guard conversationPath == nil else {
                    isUnsafeOrAmbiguous = true
                    return
                }
                conversationPath = path
                return
            }
            if transcriptContainsOnlyNonProtectiveMetadata(atPath: path, fileManager: fileManager) {
                if let current = metadataOnlyPath {
                    metadataOnlyPath = min(current, path)
                } else {
                    metadataOnlyPath = path
                }
                return
            }
            isUnsafeOrAmbiguous = true
        }
    }

    private enum ClaudeRegularFileProbe {
        case absentOrUnsupported
        case unsafe
        case regular(byteCount: UInt64)
    }

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

        func inspectWorkflowCandidate(
            _ path: String,
            accumulator: inout ClaudeTranscriptCandidateAccumulator
        ) -> Bool {
            let standardized = (path as NSString).standardizingPath
            guard seenCandidates.insert(standardized).inserted else { return true }
            accumulator.inspect(path: path, fileManager: fileManager)
            return !accumulator.isUnsafeOrAmbiguous
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
        var exactProjectRoots: [String] = []
        if let workingDirectory = normalized(agent.workingDirectory) {
            var standardCandidates: [String] = []
            for configRoot in configRoots {
                let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
                let projectRoot = (projectsRoot as NSString)
                    .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory))
                exactProjectRoots.append(projectRoot)
                for candidate in transcriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId) {
                    appendCandidate(candidate, to: &standardCandidates)
                }
            }
            let standardResolution = resolve(standardCandidates, requireUniqueConversation: true)
            if standardResolution.shouldStop { return standardResolution.path }
        }

        var workflowBudget = ClaudeWorkflowScanBudget()
        if !exactProjectRoots.isEmpty {
            var exactWorkflowResolution = ClaudeTranscriptCandidateAccumulator()
            for projectRoot in exactProjectRoots {
                let completed = scanClaudeWorkflowTranscripts(
                    projectRoot: projectRoot,
                    sessionId: agent.sessionId,
                    budget: &workflowBudget
                ) { candidate in
                    inspectWorkflowCandidate(candidate, accumulator: &exactWorkflowResolution)
                }
                guard completed else { return nil }
            }
            metadataOnlyCandidate = metadataOnlyCandidate ?? exactWorkflowResolution.metadataOnlyPath
            if exactWorkflowResolution.isUnsafeOrAmbiguous { return nil }
            if let conversationPath = exactWorkflowResolution.conversationPath {
                return conversationPath
            }
        }

        var fallbackProjectRoots: [String] = []
        for configRoot in configRoots {
            let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
            guard collectClaudeProjectDirectories(
                projectsRoot: projectsRoot,
                budget: &workflowBudget,
                into: &fallbackProjectRoots
            ) else {
                return nil
            }
        }
        let exactProjectRootSet = Set(exactProjectRoots.map { ($0 as NSString).standardizingPath })
        fallbackProjectRoots.removeAll { exactProjectRootSet.contains(($0 as NSString).standardizingPath) }

        var fallbackResolution = ClaudeTranscriptCandidateAccumulator()
        for projectRoot in fallbackProjectRoots {
            for candidate in transcriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId) {
                let standardized = (candidate as NSString).standardizingPath
                guard seenCandidates.insert(standardized).inserted else { continue }
                switch probeClaudeRegularFile(atPath: candidate) {
                case .absentOrUnsupported:
                    continue
                case .unsafe:
                    return nil
                case .regular(let byteCount):
                    guard workflowBudget.consumeFile(byteCount: byteCount) else { return nil }
                }
                fallbackResolution.inspect(path: candidate, fileManager: fileManager)
                if fallbackResolution.isUnsafeOrAmbiguous { return nil }
            }
        }
        for projectRoot in fallbackProjectRoots {
            let completed = scanClaudeWorkflowTranscripts(
                projectRoot: projectRoot,
                sessionId: agent.sessionId,
                budget: &workflowBudget
            ) { candidate in
                inspectWorkflowCandidate(candidate, accumulator: &fallbackResolution)
            }
            guard completed else { return nil }
        }
        metadataOnlyCandidate = metadataOnlyCandidate ?? fallbackResolution.metadataOnlyPath
        if fallbackResolution.isUnsafeOrAmbiguous { return nil }
        if let conversationPath = fallbackResolution.conversationPath {
            return conversationPath
        }
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
                if let current = metadataOnlyPath {
                    metadataOnlyPath = min(current, candidate)
                } else {
                    metadataOnlyPath = candidate
                }
                continue
            }
            return (nil, metadataOnlyPath, true)
        }
        if let conversationPath { return (conversationPath, metadataOnlyPath, true) }
        return (nil, metadataOnlyPath, false)
    }

    private static func probeClaudeRegularFile(atPath path: String) -> ClaudeRegularFileProbe {
        var pathStatus = stat()
        guard lstat(path, &pathStatus) == 0 else { return .absentOrUnsupported }
        guard pathStatus.st_mode & S_IFMT == S_IFREG else {
            return pathStatus.st_mode & S_IFMT == S_IFLNK ? .unsafe : .absentOrUnsupported
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unsafe }
        defer { Darwin.close(descriptor) }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            return .unsafe
        }
        guard descriptorStatus.st_size > 0 else { return .absentOrUnsupported }
        return .regular(byteCount: UInt64(descriptorStatus.st_size))
    }

    private static func collectClaudeProjectDirectories(
        projectsRoot: String,
        budget: inout ClaudeWorkflowScanBudget,
        into projectRoots: inout [String]
    ) -> Bool {
        let descriptor = open(projectsRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return true }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return true
        }
        defer { closedir(stream) }

        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 }
            let name = claudeDirectoryEntryName(entry)
            guard name != ".", name != ".." else { continue }
            guard budget.consumeEntry() else { return false }
            let childDescriptor = name.withCString {
                openat(dirfd(stream), $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childDescriptor >= 0 else { continue }
            Darwin.close(childDescriptor)
            projectRoots.append((projectsRoot as NSString).appendingPathComponent(name))
        }
    }

    private static func scanClaudeWorkflowTranscripts(
        projectRoot: String,
        sessionId: String,
        budget: inout ClaudeWorkflowScanBudget,
        visit: (String) -> Bool
    ) -> Bool {
        let descriptor = open(projectRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return true }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return true
        }
        let targetName = "\(sessionId).jsonl"
        let directPath = (projectRoot as NSString).appendingPathComponent(targetName)
        let nestedPath = (((projectRoot as NSString).appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent(targetName)
        let excludedPaths = Set([directPath, nestedPath].map { ($0 as NSString).standardizingPath })
        return scanClaudeWorkflowDirectory(
            stream: stream,
            directoryPath: projectRoot,
            targetName: targetName,
            excludedPaths: excludedPaths,
            remainingDirectoryDepth: 4,
            budget: &budget,
            visit: visit
        )
    }

    private static func scanClaudeWorkflowDirectory(
        stream: UnsafeMutablePointer<DIR>,
        directoryPath: String,
        targetName: String,
        excludedPaths: Set<String>,
        remainingDirectoryDepth: Int,
        budget: inout ClaudeWorkflowScanBudget,
        visit: (String) -> Bool
    ) -> Bool {
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 }
            let name = claudeDirectoryEntryName(entry)
            guard name != ".", name != ".." else { continue }
            guard budget.consumeEntry() else { return false }
            let childPath = (directoryPath as NSString).appendingPathComponent(name)

            if name == targetName {
                let standardized = (childPath as NSString).standardizingPath
                guard !excludedPaths.contains(standardized) else { continue }
                let fileDescriptor = name.withCString {
                    openat(dirfd(stream), $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard fileDescriptor >= 0 else { continue }
                var status = stat()
                let statusRead = fstat(fileDescriptor, &status)
                Darwin.close(fileDescriptor)
                guard statusRead == 0,
                      status.st_mode & S_IFMT == S_IFREG,
                      status.st_size > 0 else {
                    continue
                }
                guard budget.consumeFile(byteCount: UInt64(status.st_size)),
                      visit(childPath) else {
                    return false
                }
                continue
            }

            guard remainingDirectoryDepth > 0 else { continue }
            let childDescriptor = name.withCString {
                openat(dirfd(stream), $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childDescriptor >= 0 else { continue }
            guard let childStream = fdopendir(childDescriptor) else {
                Darwin.close(childDescriptor)
                continue
            }
            guard scanClaudeWorkflowDirectory(
                stream: childStream,
                directoryPath: childPath,
                targetName: targetName,
                excludedPaths: excludedPaths,
                remainingDirectoryDepth: remainingDirectoryDepth - 1,
                budget: &budget,
                visit: visit
            ) else {
                return false
            }
        }
    }

    private static func claudeDirectoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
            namePointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(entry.pointee.d_namlen) + 1
            ) { String(cString: $0) }
        }
    }
}
