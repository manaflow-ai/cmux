import Foundation

/// The filesystem inputs needed to make a Claude transcript resumable in a new project directory.
public struct ClaudeTranscriptForkSeedRequest: Sendable {
    public let sessionID: String
    public let sourceWorkingDirectory: String?
    public let targetWorkingDirectory: String
    public let configDirectory: String

    public init(
        sessionID: String,
        sourceWorkingDirectory: String?,
        targetWorkingDirectory: String,
        configDirectory: String
    ) {
        self.sessionID = sessionID
        self.sourceWorkingDirectory = sourceWorkingDirectory
        self.targetWorkingDirectory = targetWorkingDirectory
        self.configDirectory = configDirectory
    }
}

/// Copies Claude's transcript and sidecar into a destination project before a fork launches.
public enum ClaudeTranscriptForkSeeder {
    /// Performs discovery and copying off the caller's executor, and repairs a missing sidecar on retry.
    public static func seed(_ request: ClaudeTranscriptForkSeedRequest) async throws {
        try await Task.detached(priority: .userInitiated) {
            try seedSynchronously(request)
        }.value
    }

    private static func seedSynchronously(_ request: ClaudeTranscriptForkSeedRequest) throws {
        guard !request.sessionID.isEmpty,
              request.sessionID.range(of: #"[\\/]"#, options: .regularExpression) == nil,
              !request.targetWorkingDirectory.isEmpty else { return }

        let fileManager = FileManager.default
        let projectsRoot = (request.configDirectory as NSString).appendingPathComponent("projects")
        let targetProject = (projectsRoot as NSString).appendingPathComponent(
            encodeProjectDirectory(request.targetWorkingDirectory)
        )
        let targetTranscript = (targetProject as NSString).appendingPathComponent("\(request.sessionID).jsonl")
        let targetSidecar = (targetTranscript as NSString).deletingPathExtension
        let sourceTranscript = findSourceTranscript(
            sessionID: request.sessionID,
            sourceWorkingDirectory: request.sourceWorkingDirectory,
            projectsRoot: projectsRoot,
            fileManager: fileManager
        )
        guard let sourceTranscript else { return }

        let sourceSidecar = (sourceTranscript as NSString).deletingPathExtension
        var sourceSidecarIsDirectory: ObjCBool = false
        let hasSourceSidecar = fileManager.fileExists(
            atPath: sourceSidecar,
            isDirectory: &sourceSidecarIsDirectory
        ) && sourceSidecarIsDirectory.boolValue
        let hasTargetTranscript = fileManager.fileExists(atPath: targetTranscript)
        let hasTargetSidecar = fileManager.fileExists(atPath: targetSidecar)
        guard !hasTargetTranscript || (hasSourceSidecar && !hasTargetSidecar) else { return }

        try fileManager.createDirectory(atPath: targetProject, withIntermediateDirectories: true)
        if !hasTargetTranscript {
            try copyAtomically(sourceTranscript, to: targetTranscript, fileManager: fileManager)
        }
        if hasSourceSidecar && !hasTargetSidecar {
            try copyAtomically(sourceSidecar, to: targetSidecar, fileManager: fileManager)
        }
    }

    private static func findSourceTranscript(
        sessionID: String,
        sourceWorkingDirectory: String?,
        projectsRoot: String,
        fileManager: FileManager
    ) -> String? {
        if let sourceWorkingDirectory {
            let sourceProject = (projectsRoot as NSString).appendingPathComponent(
                encodeProjectDirectory(sourceWorkingDirectory)
            )
            let candidate = (sourceProject as NSString).appendingPathComponent("\(sessionID).jsonl")
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        guard let projectNames = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else { return nil }
        for projectName in projectNames {
            let candidate = ((projectsRoot as NSString).appendingPathComponent(projectName) as NSString)
                .appendingPathComponent("\(sessionID).jsonl")
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func copyAtomically(_ source: String, to destination: String, fileManager: FileManager) throws {
        let temporaryDestination = "\(destination).tmp-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(atPath: temporaryDestination) }
        try fileManager.copyItem(atPath: source, toPath: temporaryDestination)
        try fileManager.moveItem(atPath: temporaryDestination, toPath: destination)
    }

    private static func encodeProjectDirectory(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
