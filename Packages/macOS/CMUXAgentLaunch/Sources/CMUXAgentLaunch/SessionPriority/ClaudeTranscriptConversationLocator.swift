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
        guard !sessionID.isEmpty,
              sessionID.unicodeScalars.allSatisfy({ scalar in
                  switch scalar {
                  case "a"..."z", "A"..."Z", "0"..."9", "_", "-": return true
                  default: return false
                  }
              })
        else { return false }
        guard let location = ClaudeTranscriptForkSeeder.findSourceTranscript(
            sessionID: sessionID,
            sourceWorkingDirectory: workingDirectory,
            projectsRoot: configDirectory + "/projects",
            fileManager: fileManager
        ) else { return false }
        return try ClaudeTranscriptConversationProbe.containsConversation(atPath: location.path)
    }
}
