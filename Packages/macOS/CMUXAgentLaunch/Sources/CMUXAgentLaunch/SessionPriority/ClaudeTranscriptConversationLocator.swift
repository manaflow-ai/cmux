import Foundation

/// Finds a Claude session's transcript under a config directory and tells whether it holds a
/// conversation `claude --resume` can continue.
public enum ClaudeTranscriptConversationLocator {
    /// Whether the transcript for `sessionID` has a conversation. No transcript, or a session id
    /// outside `^[A-Za-z0-9_-]+$`, is `false`; nothing is read for an unsafe id.
    public static func hasConversation(
        sessionID: String,
        workingDirectory: String,
        configDirectory: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let path = transcriptPath(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            configDirectory: configDirectory,
            fileManager: fileManager
        ) else { return false }
        return try ClaudeTranscriptConversationProbe.containsConversation(atPath: path)
    }

    /// The transcript file of `sessionID` under `configDirectory/projects`, looked up first in
    /// the working directory's project, or `nil` when there is none. A session id outside
    /// `^[A-Za-z0-9_-]+$` is `nil` without touching the disk.
    public static func transcriptPath(
        sessionID: String,
        workingDirectory: String,
        configDirectory: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard isSafeSessionID(sessionID) else { return nil }
        return ClaudeTranscriptForkSeeder.findSourceTranscript(
            sessionID: sessionID,
            sourceWorkingDirectory: workingDirectory,
            projectsRoot: configDirectory + "/projects",
            fileManager: fileManager
        )?.path
    }

    private static func isSafeSessionID(_ sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionID.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-": return true
            default: return false
            }
        }
    }
}
