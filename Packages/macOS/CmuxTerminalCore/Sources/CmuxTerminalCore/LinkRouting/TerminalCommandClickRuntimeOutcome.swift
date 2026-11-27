/// Describes how the terminal runtime handled one command-click release.
public enum TerminalCommandClickRuntimeOutcome: Equatable, Sendable {
    /// The runtime did not consume the release.
    case unhandled
    /// The runtime consumed the release without dispatching an open-URL action.
    case consumed
    /// The runtime dispatched an open-URL action for the release.
    case openURL
}
