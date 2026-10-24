import Foundation

/// Inputs for making one Claude session resumable from another account's config directory.
public struct ClaudeTranscriptAccountSyncRequest: Sendable {
    public let sessionID: String
    public let workingDirectory: String
    public let sourceConfigDirectory: String
    public let targetConfigDirectory: String

    public init(
        sessionID: String,
        workingDirectory: String,
        sourceConfigDirectory: String,
        targetConfigDirectory: String
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.sourceConfigDirectory = sourceConfigDirectory
        self.targetConfigDirectory = targetConfigDirectory
    }
}

/// What a sync did to the target account's copy of the transcript.
public enum ClaudeTranscriptAccountSyncOutcome: String, Equatable, Sendable {
    /// The target had no transcript; it was copied in.
    case copied
    /// The target was older than the source (or missing its sidecar); it was replaced.
    case refreshed
    /// The target was at least as new as the source; nothing was changed.
    case alreadyCurrent
}

/// Why a sync could not run.
public enum ClaudeTranscriptAccountSyncError: Error, Equatable {
    case invalidSessionID
    /// The source account has no transcript for the session. Claude Code creates it on the
    /// session's first turn, so a session nobody has sent a message to has none.
    case transcriptNotFound
    /// The source transcript has no conversation record, only session metadata, so
    /// `claude --resume` would find no conversation in it.
    case noConversation
}

/// Copies or refreshes a Claude transcript (and its sidecar directory) from one account config dir
/// into another so `claude --resume <id>` continues the same conversation under the target account.
/// A source with no conversation yet is refused before the target is touched, because resuming it
/// would fail (``ClaudeTranscriptAccountSyncError/transcriptNotFound`` and
/// ``ClaudeTranscriptAccountSyncError/noConversation``).
///
/// Nothing is ever deleted from the source, and a newer target is never overwritten. The transcript
/// and the sidecar are each staged as a temporary sibling in the target directory and then swapped
/// in, so a failure never leaves a partial file at the final path. Files use
/// `FileManager.replaceItemAt` (atomic exchange). The sidecar directory uses `replaceItemAt` too,
/// which supports directories and swaps the whole tree in one step, so there is no window where
/// the sidecar is absent. The sidecar is replaced before the transcript: if the process dies in
/// between, the transcript's mtime still looks stale and the next sync repeats the refresh.
public struct ClaudeTranscriptAccountSync: Sendable {
    public init() {}

    /// Performs discovery and copying off the caller's executor.
    public func sync(_ request: ClaudeTranscriptAccountSyncRequest) async throws -> ClaudeTranscriptAccountSyncOutcome {
        try await Task.detached(priority: .userInitiated) {
            try Self.syncSynchronously(request)
        }.value
    }

    private static func syncSynchronously(
        _ request: ClaudeTranscriptAccountSyncRequest
    ) throws -> ClaudeTranscriptAccountSyncOutcome {
        guard request.sessionID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ClaudeTranscriptAccountSyncError.invalidSessionID
        }
        let fileManager = FileManager.default
        let sourceProjects = (request.sourceConfigDirectory as NSString).appendingPathComponent("projects")
        guard let source = ClaudeTranscriptForkSeeder.findSourceTranscript(
            sessionID: request.sessionID,
            sourceWorkingDirectory: request.workingDirectory,
            projectsRoot: sourceProjects,
            fileManager: fileManager
        ) else { throw ClaudeTranscriptAccountSyncError.transcriptNotFound }
        // Checked before the target is looked at: a copy there, even an equally new one, cannot
        // make a conversation the source does not have resumable.
        guard try ClaudeTranscriptConversationProbe.containsConversation(atPath: source.path) else {
            throw ClaudeTranscriptAccountSyncError.noConversation
        }

        let targetProject = ((request.targetConfigDirectory as NSString).appendingPathComponent("projects")
            as NSString).appendingPathComponent(
                ClaudeProjectSlug().slug(forWorkingDirectory: request.workingDirectory)
            )
        let targetTranscript = (targetProject as NSString).appendingPathComponent(source.relativePath)
        let targetSidecar = (targetProject as NSString).appendingPathComponent(request.sessionID)
        let sourceSidecar = (source.projectPath as NSString).appendingPathComponent(request.sessionID)

        var isDirectory: ObjCBool = false
        let hasSourceSidecar = fileManager.fileExists(atPath: sourceSidecar, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let hasTargetTranscript = fileManager.fileExists(atPath: targetTranscript)
        let sourceDate = try modificationDate(source.path, fileManager)

        var outcome = ClaudeTranscriptAccountSyncOutcome.copied
        let needsSidecar = hasSourceSidecar
        if hasTargetTranscript {
            let targetDate = try modificationDate(targetTranscript, fileManager)
            // 1 ms slack absorbs Date/timespec rounding when we stamp the copy with the source mtime.
            let isStale = sourceDate.timeIntervalSince(targetDate) > 0.001
            let missingSidecar = hasSourceSidecar && !fileManager.fileExists(atPath: targetSidecar)
            guard isStale || missingSidecar else { return .alreadyCurrent }
            outcome = .refreshed
            if !isStale {
                try replace(sourceSidecar, with: targetSidecar, fileManager)
                return outcome
            }
        }
        try fileManager.createDirectory(atPath: targetProject, withIntermediateDirectories: true)
        if needsSidecar { try replace(sourceSidecar, with: targetSidecar, fileManager) }
        try replace(source.path, with: targetTranscript, fileManager, modificationDate: sourceDate)
        return outcome
    }

    private static func modificationDate(_ path: String, _ fileManager: FileManager) throws -> Date {
        (try fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Stages `source` as a temp sibling of `destination`, then swaps it in; cleans the temp on failure.
    private static func replace(
        _ source: String, with destination: String, _ fileManager: FileManager, modificationDate: Date? = nil
    ) throws {
        let parent = (destination as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let temporary = "\(destination).tmp-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(atPath: temporary) }
        try fileManager.copyItem(atPath: source, toPath: temporary)
        if let modificationDate {
            // Keep the source's mtime so the next sync sees the target as current.
            try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: temporary)
        }
        if fileManager.fileExists(atPath: destination) {
            _ = try fileManager.replaceItemAt(
                URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: temporary)
            )
        } else {
            try fileManager.moveItem(atPath: temporary, toPath: destination)
        }
    }
}
