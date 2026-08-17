/// Privacy-safe operation boundaries emitted by ``ChatConversationStore``.
///
/// Events never carry prompt text, transcript content, paths, titles, or raw
/// identifiers. Failures are passed only to the synchronous main-actor
/// observer so an app can reduce them to its own bounded taxonomy.
public enum ChatConversationDiagnosticEvent {
    case eventStreamStarted
    case eventStreamEnded
    case historyLoadStarted
    case historyLoadSucceeded(messageCount: Int)
    case historyLoadFailed(any Error)
    case olderHistoryLoadStarted
    case olderHistoryLoadSucceeded(messageCount: Int)
    case olderHistoryLoadFailed(any Error)
    case messageSubmitStarted(attachmentCount: Int)
    case messageSubmitQueued
    case messageSubmitSucceeded
    case messageSubmitFailed(any Error)
    case messageRetried
    case interruptSucceeded
    case interruptFailed(any Error)
    case answerSucceeded(ChatAnswerKind)
    case answerFailed(ChatAnswerKind, any Error)
    case artifactDiscovered(count: Int)
    case artifactOpened
    case blockDetailOpened
    case composerAttachmentAdded(count: Int)
    case composerAttachmentRemoved(count: Int)
    case photoPickerOpened
    case photoPickerSelected(count: Int)
    case photoPickerDismissed
    case composerAttachmentPreparationStarted
    case composerAttachmentPreparationSucceeded(byteCount: Int)
    case composerAttachmentPreparationFailed
}

/// The actionable card answered through the shared chat source.
public enum ChatAnswerKind: Sendable, Equatable {
    case permission
    case question
}
