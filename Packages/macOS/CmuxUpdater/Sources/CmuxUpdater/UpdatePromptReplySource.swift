/// Why cmux consumed a Sparkle update prompt.
///
/// Sparkle's later `dismissUpdateInstallation` callback does not identify the prompt or the
/// action that caused it. Recording the cause at the reply boundary lets the lifecycle owner
/// distinguish an explicit user choice from a controller transition or accepted install.
@MainActor
enum UpdatePromptReplySource: String {
    case user
    case superseded
    case installAttempt
}
