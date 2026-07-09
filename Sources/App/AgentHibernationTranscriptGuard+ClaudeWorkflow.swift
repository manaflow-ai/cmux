import Foundation

extension AgentHibernationTranscriptGuard {
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
        collectWorkflowTranscriptCandidates(
            inDirectory: projectRoot,
            targetName: targetName,
            excludedPaths: standardPaths,
            remainingDirectoryDepth: 4,
            fileManager: fileManager,
            matches: &matches
        )
        return matches.count == 1 ? matches : []
    }

    private static func collectWorkflowTranscriptCandidates(
        inDirectory directory: String,
        targetName: String,
        excludedPaths: Set<String>,
        remainingDirectoryDepth: Int,
        fileManager: FileManager,
        matches: inout [String]
    ) {
        guard matches.count < 2,
              let children = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return
        }
        for child in children.sorted() {
            guard matches.count < 2 else { return }
            let childPath = (directory as NSString).appendingPathComponent(child)
            if child == targetName {
                let standardized = (childPath as NSString).standardizingPath
                guard !excludedPaths.contains(standardized),
                      workflowRegularNonEmptyFileExists(atPath: childPath, fileManager: fileManager) else {
                    continue
                }
                matches.append(childPath)
            } else if remainingDirectoryDepth > 0,
                      workflowDirectoryExists(atPath: childPath, fileManager: fileManager) {
                collectWorkflowTranscriptCandidates(
                    inDirectory: childPath,
                    targetName: targetName,
                    excludedPaths: excludedPaths,
                    remainingDirectoryDepth: remainingDirectoryDepth - 1,
                    fileManager: fileManager,
                    matches: &matches
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
