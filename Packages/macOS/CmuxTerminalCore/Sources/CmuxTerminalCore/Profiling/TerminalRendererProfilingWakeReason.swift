/// Typed renderer wake sources. Cases intentionally cannot carry user content.
public enum TerminalRendererProfilingWakeReason: String, Sendable {
    /// Terminal output or an otherwise unattributed Ghostty renderer wake.
    case terminalOutput = "terminal-output"

    /// A display-link callback requested a frame.
    case displayLink = "display-link"

    /// An explicit cmux refresh requested an update.
    case explicitRefresh = "explicit-refresh"

    /// Showing a previously hidden surface requested an update.
    case visibility = "visibility"

    /// A focus transition requested an update.
    case focus = "focus"
}
