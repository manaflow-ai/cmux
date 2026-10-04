import Foundation

/// The filesystem inputs needed to make a Claude transcript resumable in a new project directory.
public struct ClaudeTranscriptForkSeedRequest: Sendable {
    public let sessionID: String
    public let sourceWorkingDirectory: String?
    public let targetWorkingDirectory: String
    public let configDirectory: String
    public let sourceConfigDirectories: [String]

    public init(
        sessionID: String,
        sourceWorkingDirectory: String?,
        targetWorkingDirectory: String,
        configDirectory: String,
        sourceConfigDirectories: [String] = []
    ) {
        self.sessionID = sessionID
        self.sourceWorkingDirectory = sourceWorkingDirectory
        self.targetWorkingDirectory = targetWorkingDirectory
        self.configDirectory = configDirectory
        self.sourceConfigDirectories = sourceConfigDirectories
    }
}

/// Copies Claude's transcript and sidecar into a destination project before a fork launches.
public struct ClaudeTranscriptForkSeeder: Sendable {
    public init() {}
    /// Performs discovery and copying off the caller's executor, and repairs a missing sidecar on retry.
    public func seed(_ request: ClaudeTranscriptForkSeedRequest) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.seedSynchronously(request)
        }.value
    }

    private static func seedSynchronously(_ request: ClaudeTranscriptForkSeedRequest) throws {
        guard request.sessionID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              request.configDirectory.hasPrefix("/"),
              !request.targetWorkingDirectory.isEmpty else { return }

        let fileManager = FileManager.default
        let projectsRoot = (request.configDirectory as NSString).appendingPathComponent("projects")
        let targetProject = (projectsRoot as NSString).appendingPathComponent(
            ClaudeProjectSlug().slug(forWorkingDirectory: request.targetWorkingDirectory)
        )
        let sourceRoots = ([request.configDirectory] + request.sourceConfigDirectories)
            .filter { $0.hasPrefix("/") }
            .reduce(into: [String]()) { roots, root in
                if !roots.contains(root) { roots.append(root) }
            }
        let sourceTranscript = sourceRoots.lazy.compactMap { root in
            findSourceTranscript(
                sessionID: request.sessionID,
                sourceWorkingDirectory: request.sourceWorkingDirectory,
                projectsRoot: (root as NSString).appendingPathComponent("projects"),
                fileManager: fileManager
            )
        }.first
        guard let sourceTranscript else { return }
        let targetTranscript = (targetProject as NSString).appendingPathComponent(sourceTranscript.relativePath)
        let targetSidecar = (targetProject as NSString).appendingPathComponent(request.sessionID)

        let sourceSidecar = (sourceTranscript.projectPath as NSString).appendingPathComponent(request.sessionID)
        var sourceSidecarIsDirectory: ObjCBool = false
        let hasSourceSidecar = fileManager.fileExists(
            atPath: sourceSidecar,
            isDirectory: &sourceSidecarIsDirectory
        ) && sourceSidecarIsDirectory.boolValue
        let hasTargetTranscript = fileManager.fileExists(atPath: targetTranscript)
        let hasTargetSidecar = fileManager.fileExists(atPath: targetSidecar)
        guard !hasTargetTranscript || (hasSourceSidecar && !hasTargetSidecar) else { return }

        try fileManager.createDirectory(atPath: targetProject, withIntermediateDirectories: true)
        if hasSourceSidecar && !hasTargetSidecar {
            try copyAtomically(sourceSidecar, to: targetSidecar, fileManager: fileManager)
        }
        if !hasTargetTranscript && !fileManager.fileExists(atPath: targetTranscript) {
            try copyAtomically(sourceTranscript.path, to: targetTranscript, fileManager: fileManager)
        }
    }

    private static func findSourceTranscript(
        sessionID: String,
        sourceWorkingDirectory: String?,
        projectsRoot: String,
        fileManager: FileManager
    ) -> TranscriptLocation? {
        if let sourceWorkingDirectory {
            let sourceProject = (projectsRoot as NSString).appendingPathComponent(
                ClaudeProjectSlug().slug(forWorkingDirectory: sourceWorkingDirectory)
            )
            if let location = transcriptLocation(
                projectPath: sourceProject, sessionID: sessionID, fileManager: fileManager
            ) { return location }
        }
        guard let projectNames = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else { return nil }
        for projectName in projectNames {
            let projectPath = (projectsRoot as NSString).appendingPathComponent(projectName)
            if let location = transcriptLocation(
                projectPath: projectPath, sessionID: sessionID, fileManager: fileManager
            ) { return location }
        }
        return nil
    }

    private static func transcriptLocation(
        projectPath: String, sessionID: String, fileManager: FileManager
    ) -> TranscriptLocation? {
        let candidates = [
            "\(sessionID).jsonl",
            "\(sessionID)/messages/\(sessionID).jsonl"
        ]
        for relativePath in candidates {
            let path = (projectPath as NSString).appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
            else { continue }
            return TranscriptLocation(path: path, projectPath: projectPath, relativePath: relativePath)
        }
        return nil
    }

    private struct TranscriptLocation {
        let path: String
        let projectPath: String
        let relativePath: String
    }

    private static func copyAtomically(_ source: String, to destination: String, fileManager: FileManager) throws {
        let destinationDirectory = (destination as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        let temporaryDestination = "\(destination).tmp-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(atPath: temporaryDestination) }
        try fileManager.copyItem(atPath: source, toPath: temporaryDestination)
        try fileManager.moveItem(atPath: temporaryDestination, toPath: destination)
    }

}
