import Foundation

/// Injects the chat-registry side effect authored by a structured restore.
struct AgentChatResumeIntentRecorder {
    /// The immutable chat-to-terminal binding produced by one restore.
    struct Intent: Equatable {
        let sessionID: String
        let source: String
        let surfaceID: String?
        let workspaceID: String?
        let workingDirectory: String?
    }

    private let recordIntent: @MainActor (Intent) -> Void

    /// Creates a recorder, defaulting to the live transcript service bridge.
    ///
    /// - Parameter recordIntent: Receives each authoritative restore binding.
    init(
        recordIntent: @escaping @MainActor (Intent) -> Void = { intent in
            AgentChatTranscriptService.recordResumeIntent(
                sessionID: intent.sessionID,
                source: intent.source,
                surfaceID: intent.surfaceID,
                workspaceID: intent.workspaceID,
                workingDirectory: intent.workingDirectory
            )
        }
    ) {
        self.recordIntent = recordIntent
    }

    /// Records a resumed chat against its actual workspace and terminal IDs.
    @MainActor
    func record(
        sessionID: String,
        source: String,
        surfaceID: String?,
        workspaceID: String?,
        workingDirectory: String?
    ) {
        recordIntent(Intent(
            sessionID: sessionID,
            source: source,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory
        ))
    }
}
