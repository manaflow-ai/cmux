/// A browser keyboard automation action that consumes a canonical keyboard event.
public enum BrowserKeyboardAction: Sendable {
    /// Dispatches keydown, optional keypress, and keyup as one action.
    case press

    /// Dispatches only keydown.
    case keyDown

    /// Dispatches only keyup.
    case keyUp
}
