/// Selects which of a notification hook's two output streams a chunk of bytes
/// belongs to when accumulated by ``NotificationHookPipeBuffer``.
public enum NotificationHookOutputStream {
    /// The hook's standard output, whose bytes become the policy patch.
    case stdout
    /// The hook's standard error, captured for failure diagnostics.
    case stderr
}
