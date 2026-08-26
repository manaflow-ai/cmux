/// The bounded result of reading a terminal surface's native selection.
public enum TerminalSurfaceSelectionRead: Equatable, Sendable {
    /// No selection is currently active on the live surface.
    case none

    /// A selection was captured as bounded UTF-8 text.
    case selected(text: String)

    /// The surface could not provide a bounded selection read.
    case unavailable
}
