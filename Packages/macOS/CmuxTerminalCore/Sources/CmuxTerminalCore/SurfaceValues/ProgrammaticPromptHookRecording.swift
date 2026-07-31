/// Whether an accepted programmatic prompt still needs its later agent hook
/// to record the submitted message.
public enum ProgrammaticPromptHookRecording: Equatable, Sendable {
    /// Record the prompt when its agent hook confirms submission.
    case recordWhenConfirmed
    /// The initiating path recorded the prompt before the hook arrived.
    case alreadyRecorded
}
