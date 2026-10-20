/// Selects the exclusive action for one command-click release.
public enum TerminalCommandClickRoute: Equatable, Sendable {
    /// Keep the open-URL action already dispatched by the terminal runtime.
    case runtimeOpenURL
    /// Open the resolved local path through cmux's fallback path.
    case pathFallback(TerminalCommandClickResolvedPath)
    /// Perform no cmux fallback action.
    case none
}
