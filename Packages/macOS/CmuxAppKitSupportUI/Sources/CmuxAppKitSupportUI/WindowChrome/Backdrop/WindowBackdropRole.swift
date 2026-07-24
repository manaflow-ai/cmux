/// A chrome surface that can receive a resolved backdrop policy.
public enum WindowBackdropRole: Sendable {
    /// The full window root backdrop.
    case windowRoot

    /// Terminal content canvas.
    case terminalCanvas

    /// Bonsplit tab and split chrome.
    case bonsplitChrome

    /// Custom titlebar band.
    case titlebar

    /// Left workspace sidebar.
    case leftSidebar

    /// Right tools sidebar.
    case rightSidebar

    /// Browser surface background.
    case browserSurface
}
